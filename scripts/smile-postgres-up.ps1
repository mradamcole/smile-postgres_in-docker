# Find the newest SmileCDR Docker tarball in Downloads, load it, and start
# SmileCDR + PostgreSQL with Postgres as the default database.
[CmdletBinding()]
param(
    [string]$DownloadsDir = "",
    [string]$Tarball = "",
    [switch]$DryRun,
    [switch]$Down,
    [switch]$ForceLoad,
    [switch]$UpdatePorts,
    [string]$Project = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..")
$DockerDir = Join-Path $RepoRoot "docker"
$ConfigFile = Join-Path $RepoRoot "config.env"
$EnvExample = Join-Path $RepoRoot ".env.example"
$SecretsFile = Join-Path $RepoRoot ".env"

if (-not $DownloadsDir) {
    $DownloadsDir = Join-Path $env:USERPROFILE "Downloads"
}

function Write-ErrExit([string]$Message) {
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

function Write-TextFile([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-Docker([string[]]$DockerArgs) {
    # Pass args as an array (Invoke-Docker @('compose','-f',...)) so switches like
    # -f / -d are not bound as PowerShell parameters.
    # Write-Host keeps docker stdout off the success pipeline so callers can
    # capture only the exit code with $code = Invoke-Docker ...
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker @DockerArgs 2>&1 | ForEach-Object {
        Write-Host $_
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return $code
}

function Write-TextLines([string]$Path, [string[]]$Lines) {
    $content = ($Lines -join "`n") + "`n"
    Write-TextFile -Path $Path -Content $content
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-VersionFromName([string]$Name) {
    if ($Name -match '^smilecdr-(\d{4}\.\d{2}\.R\d+)-(docker\.tar\.gz|image\.tar\.bz2)$') {
        return $Matches[1]
    }
    return $null
}

function Get-VersionSortKey([string]$Version) {
    if ($Version -match '^(\d{4})\.(\d{2})\.R(\d+)$') {
        return ([int]$Matches[1] * 1000000) + ([int]$Matches[2] * 1000) + [int]$Matches[3]
    }
    return 0
}

function Find-LatestTarball([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-ErrExit "downloads directory not found: $Dir"
    }

    $candidates = @()
    $candidates += Get-ChildItem -LiteralPath $Dir -File -Filter "smilecdr-*-docker.tar.gz" -ErrorAction SilentlyContinue
    $candidates += Get-ChildItem -LiteralPath $Dir -File -Filter "smilecdr-*-image.tar.bz2" -ErrorAction SilentlyContinue

    $best = $null
    $bestKey = -1
    $bestVersion = $null

    foreach ($f in $candidates) {
        $ver = Get-VersionFromName $f.Name
        if (-not $ver) { continue }
        $key = Get-VersionSortKey $ver
        if ($key -gt $bestKey) {
            $bestKey = $key
            $best = $f.FullName
            $bestVersion = $ver
        }
    }

    if (-not $best) {
        Write-ErrExit "no SmileCDR tarball found in $Dir (expected smilecdr-YYYY.MM.RXX-docker.tar.gz)"
    }

    return @{ Path = $best; Version = $bestVersion }
}

function Resolve-PostgresMajor([int]$Fallback = 17) {
    # Probe descending majors; Hub "last_updated" pages miss older major tags.
    foreach ($major in @(20, 19, 18, 17, 16, 15, 14)) {
        try {
            $uri = "https://hub.docker.com/v2/repositories/library/postgres/tags/${major}-alpine"
            Invoke-RestMethod -Uri $uri -TimeoutSec 10 | Out-Null
            return $major
        }
        catch {
            # try next major
        }
    }
    return $Fallback
}

function Test-DockerImage([string]$Image) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker image inspect $Image 1>$null 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return ($code -eq 0)
}

function Import-DotEnv([string]$Path) {
    $map = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        $map[$key] = $value
        Set-Item -Path "Env:$key" -Value $value
    }
    return $map
}

function Set-Prop([string]$File, [string]$Key, [string]$Value) {
    $lines = Get-Content -LiteralPath $File
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*([^=\s]+)\s*=') {
            $k = $Matches[1]
            if ($k -eq $Key) {
                $prefix = ($line -split '=', 2)[0]
                $found = $true
                "$prefix=$Value"
                continue
            }
        }
        $line
    }
    if (-not $found) {
        $out += "$Key=$Value"
    }
    Write-TextLines -Path $File -Lines @($out)
}

function Update-SmileConfig {
    param(
        [string]$File,
        [string]$DbName,
        [string]$DbUser,
        [string]$DbPassword,
        [hashtable]$Ports
    )

    $jdbc = "jdbc:postgresql://postgresdb:5432/$DbName"
    Set-Prop $File "module.clustermgr.config.db.driver" "POSTGRES_9_4"
    Set-Prop $File "module.persistence.config.db.driver" "POSTGRES_9_4"
    Set-Prop $File "module.clustermgr.config.db.url" $jdbc
    Set-Prop $File "module.persistence.config.db.url" $jdbc
    Set-Prop $File "module.clustermgr.config.db.username" $DbUser
    Set-Prop $File "module.clustermgr.config.db.password" $DbPassword
    Set-Prop $File "module.persistence.config.db.username" $DbUser
    Set-Prop $File "module.persistence.config.db.password" $DbPassword

    Set-Prop $File "module.fhir_endpoint.config.port" $Ports.FHIR_PORT
    Set-Prop $File "module.fhirweb_endpoint.config.port" $Ports.FHIRWEB_PORT
    Set-Prop $File "module.admin_json.config.port" $Ports.ADMIN_JSON_PORT
    Set-Prop $File "module.admin_web.config.port" $Ports.ADMIN_WEB_PORT
    Set-Prop $File "module.smart_auth.config.port" $Ports.SMART_AUTH_PORT
    Set-Prop $File "module.smart_app_demo_host.config.port" $Ports.SMART_DEMO_PORT

    $raw = Get-Content -LiteralPath $File -Raw
    if ($raw -match '(?m)^\s*module\.fhir_endpoint\.config\.base_url\.fixed\s*=') {
        Set-Prop $File "module.fhir_endpoint.config.base_url.fixed" "http://localhost:$($Ports.FHIR_PORT)"
    }

    # License JWT from container env (SMILE_LICENSE_KEY in repo-root .env).
    Set-Prop $File "module.license.config.jwt_text" "#{env['SMILE_LICENSE_KEY']}"
}

function Get-ComposeEnvFileArgs {
    [string[]]$argsList = @("--env-file", "$ConfigFile")
    if (Test-Path -LiteralPath $SecretsFile) {
        $argsList += [string[]]@("--env-file", "$SecretsFile")
    }
    return [string[]]$argsList
}

function Test-HostBindBlocked([int]$Port) {
    # Secondary check for non-Docker listeners. On Windows + Docker Desktop,
    # published container ports often do NOT block TcpListener, so Docker
    # publish maps are checked separately.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
    try {
        $listener.Start()
        $listener.Stop()
        return $false
    }
    catch {
        return $true
    }
    finally {
        try { $listener.Stop() } catch { }
    }
}

function Find-DockerPortHolder([int]$Port) {
    # Match host publish forms: 0.0.0.0:8000->... and 0.0.0.0:8000-8002->...
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $lines = & docker ps --format "{{.Names}}`t{{.Ports}}" 2>$null
    $ErrorActionPreference = $prevEap
    if (-not $lines) { return $null }

    foreach ($line in $lines) {
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $name = $parts[0]
        $ports = $parts[1]
        $matches = [regex]::Matches($ports, '(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):(\d+)(?:-(\d+))?->')
        foreach ($m in $matches) {
            $start = [int]$m.Groups[1].Value
            $end = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { $start }
            if ($Port -ge $start -and $Port -le $end) {
                return $name
            }
        }
    }
    return $null
}

function Test-PortHeldByOurStack {
    param(
        [string]$Holder,
        [string]$SmileVersion
    )
    if (-not $Holder) { return $false }
    return ($Holder -eq "smilecdr-$SmileVersion" -or $Holder -eq "postgres_cdr-$SmileVersion")
}

function Assert-HostPortsAvailable {
    param(
        [hashtable]$PortMap,
        [string]$SmileVersion,
        [string]$ConfigPath
    )

    $busy = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($name in @($PortMap.Keys | Sort-Object)) {
        $port = [int]$PortMap[$name]
        if ($seen.ContainsKey($port)) { continue }
        $seen[$port] = $true

        $dockerHolder = Find-DockerPortHolder -Port $port
        if ($dockerHolder) {
            if (Test-PortHeldByOurStack -Holder $dockerHolder -SmileVersion $SmileVersion) {
                continue
            }
            [void]$busy.Add("${name}=${port} (Docker container: ${dockerHolder})")
            continue
        }

        if (Test-HostBindBlocked -Port $port) {
            [void]$busy.Add("${name}=${port} (in use on this host)")
        }
    }

    if ($busy.Count -eq 0) { return }

    [Console]::Error.WriteLine("warning: one or more host ports from config.env are already in use:")
    foreach ($detail in $busy) {
        [Console]::Error.WriteLine("  - $detail")
    }
    [Console]::Error.WriteLine("Edit $ConfigPath, choose free ports, then re-run this script.")
    [Console]::Error.WriteLine("Tip: ports already used by smilecdr-$SmileVersion / postgres_cdr-$SmileVersion are ignored (stack refresh).")
    exit 1
}

function Expand-ComposeTemplate {
    param(
        [string]$Template,
        [string]$OutFile,
        [string]$Version,
        [string]$PostgresTag,
        [string]$Platform
    )
    $content = Get-Content -LiteralPath $Template -Raw
    $content = $content.Replace("__SMILECDR_VERSION__", $Version)
    $content = $content.Replace("__POSTGRES_TAG__", $PostgresTag)
    $content = $content.Replace("__SMILECDR_PLATFORM__", $Platform)
    Write-TextFile -Path $OutFile -Content $content
}

function Get-PostgresTagFromCompose([string]$ComposePath) {
    if (-not (Test-Path -LiteralPath $ComposePath)) { return $null }
    foreach ($line in Get-Content -LiteralPath $ComposePath) {
        if ($line -match '^\s*image:\s*postgres_cdr:(\S+)') {
            return $Matches[1]
        }
    }
    return $null
}

function Invoke-PortUpdates {
    param(
        [string]$ConfigPath,
        [string]$ComposePath,
        [string]$PostgresTag,
        [string]$ProjectName,
        [string[]]$ComposeEnvArgs,
        [hashtable]$Ports,
        [string]$DbName,
        [string]$DbUser,
        [string]$DbPassword,
        [string]$SmileVersion,
        [string]$Platform,
        [string]$TemplatePath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-ErrExit "missing $ConfigPath; run without -UpdatePorts first"
    }
    if (-not (Test-Path -LiteralPath $ComposePath)) {
        Write-ErrExit "missing $ComposePath; run without -UpdatePorts first"
    }

    Update-SmileConfig -File $ConfigPath -DbName $DbName -DbUser $DbUser -DbPassword $DbPassword -Ports $Ports
    Expand-ComposeTemplate -Template $TemplatePath -OutFile $ComposePath -Version $SmileVersion -PostgresTag $PostgresTag -Platform $Platform

    Write-Host "Applying port changes (volumes unchanged; containers recreated only if publish mappings changed)..."
    $buildCode = Invoke-Docker (@(
        "compose", "-f", $ComposePath,
        "--project-name", $ProjectName
    ) + $ComposeEnvArgs + @("build", "smilecdr"))
    if ($buildCode -ne 0) { exit $buildCode }

    $upCode = Invoke-Docker (@(
        "compose", "-f", $ComposePath,
        "--project-name", $ProjectName
    ) + $ComposeEnvArgs + @("up", "-d"))
    if ($upCode -ne 0) { exit $upCode }
}

function Get-ConfigFromImage([string]$Image, [string]$Dest) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $cid = (& docker create $Image 2>$null | Out-String).Trim()
    $ErrorActionPreference = $prevEap
    if (-not $cid) {
        Write-ErrExit "failed to create temporary container from $Image"
    }
    try {
        $code = Invoke-Docker @(
            "cp",
            "${cid}:/home/smile/smilecdr/classes/cdr-config-Master.properties",
            $Dest
        )
        if ($code -ne 0) {
            Write-ErrExit "failed to extract cdr-config-Master.properties from $Image"
        }
    }
    finally {
        [void](Invoke-Docker @("rm", "-f", $cid))
    }
}

# --- Resolve tarball / version ---
if ($Tarball) {
    if (-not (Test-Path -LiteralPath $Tarball)) {
        Write-ErrExit "tarball not found: $Tarball"
    }
    $SmileVersion = Get-VersionFromName ([IO.Path]::GetFileName($Tarball))
    if (-not $SmileVersion) {
        Write-ErrExit "cannot parse SmileCDR version from filename: $([IO.Path]::GetFileName($Tarball))"
    }
}
else {
    $found = Find-LatestTarball $DownloadsDir
    $Tarball = $found.Path
    $SmileVersion = $found.Version
}

$RuntimeDir = Join-Path $RepoRoot ".runtime\smilecdr-$SmileVersion"
$ComposeFile = Join-Path $RuntimeDir "docker-compose.yml"
# Compose project names: lowercase alphanumeric, hyphens, underscores only.
$SafeVersion = ($SmileVersion -replace '\.', '-').ToLowerInvariant()
$ProjectName = if ($Project) { $Project } else { "smilecdr-$SafeVersion" }

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    Write-ErrExit "missing $ConfigFile"
}
if (-not (Test-Path -LiteralPath $SecretsFile)) {
    if (-not (Test-Path -LiteralPath $EnvExample)) {
        Write-ErrExit "missing $EnvExample"
    }
    $envText = [System.IO.File]::ReadAllText($EnvExample) -replace "`r`n", "`n" -replace "`r", "`n"
    Write-TextFile -Path $SecretsFile -Content $envText
    Write-Host "Created $SecretsFile from .env.example — set SMILE_LICENSE_KEY if you need premium modules."
}

# Non-secret settings first; .env secrets override on name collision.
Import-DotEnv $ConfigFile | Out-Null
Import-DotEnv $SecretsFile | Out-Null
$ComposeEnvArgs = Get-ComposeEnvFileArgs

function Get-EnvOr([string]$Name, [string]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

$PostgresMajorFallback = [int](Get-EnvOr "POSTGRES_MAJOR" "17")
$SmilePlatform = Get-EnvOr "SMILECDR_PLATFORM" "linux/amd64"
$FhirPort = Get-EnvOr "FHIR_PORT" "8000"
$FhirWebPort = Get-EnvOr "FHIRWEB_PORT" "8001"
$AdminJsonPort = Get-EnvOr "ADMIN_JSON_PORT" "9000"
$AdminWebPort = Get-EnvOr "ADMIN_WEB_PORT" "9100"
$SmartAuthPort = Get-EnvOr "SMART_AUTH_PORT" "9200"
$SmartDemoPort = Get-EnvOr "SMART_DEMO_PORT" "9201"
$PostgresHostPort = Get-EnvOr "POSTGRES_HOST_PORT" "5432"
$DbCdrName = Get-EnvOr "DB_CDR_NAME" "cdr"
$DbCdrUser = Get-EnvOr "DB_CDR_USER" "cdr"
$DbCdrPassword = Get-EnvOr "DB_CDR_PASSWORD" "SmileCDR"

$ResolvedMajor = Resolve-PostgresMajor -Fallback $PostgresMajorFallback
$PostgresTag = "$ResolvedMajor-alpine"
$ImageTag = "smilecdr:$SmileVersion"

Write-Host "SmileCDR version:  $SmileVersion"
Write-Host "Tarball:           $Tarball"
Write-Host "Postgres image:    postgres:$PostgresTag"
Write-Host "Runtime dir:       $RuntimeDir"
Write-Host "Compose project:   $ProjectName"
Write-Host "Platform:          $SmilePlatform"

if ($UpdatePorts -and $Down) {
    Write-ErrExit "use either -UpdatePorts or -Down, not both"
}
if ($UpdatePorts -and $ForceLoad) {
    Write-ErrExit "use either -UpdatePorts or -ForceLoad, not both"
}

if (-not $Down) {
    Assert-HostPortsAvailable -PortMap @{
        FHIR_PORT           = $FhirPort
        FHIRWEB_PORT        = $FhirWebPort
        ADMIN_JSON_PORT     = $AdminJsonPort
        ADMIN_WEB_PORT      = $AdminWebPort
        SMART_AUTH_PORT     = $SmartAuthPort
        SMART_DEMO_PORT     = $SmartDemoPort
        POSTGRES_HOST_PORT  = $PostgresHostPort
    } -SmileVersion $SmileVersion -ConfigPath $ConfigFile
}

if ($Down) {
    if (-not (Test-Command "docker")) {
        Write-ErrExit "required command not found: docker"
    }
    if (-not (Test-Path -LiteralPath $ComposeFile)) {
        Write-ErrExit "no generated compose file at $ComposeFile; run without -Down first"
    }
    if ($DryRun) {
        Write-Host "[dry-run] would run: docker compose -f $ComposeFile --project-name $ProjectName $($ComposeEnvArgs -join ' ') down"
        exit 0
    }
    $code = Invoke-Docker (@(
        "compose", "-f", $ComposeFile,
        "--project-name", $ProjectName
    ) + $ComposeEnvArgs + @("down"))
    if ($code -ne 0) { exit $code }
    Write-Host "Stack stopped."
    exit 0
}

if ($UpdatePorts) {
    $ConfigPath = Join-Path $RuntimeDir "cdr-config-Master.properties"
    $postgresTagFromCompose = Get-PostgresTagFromCompose -ComposePath $ComposeFile
    if (-not $postgresTagFromCompose) {
        Write-ErrExit "cannot read Postgres tag from $ComposeFile; run a full up first"
    }
    if ($DryRun) {
        Write-Host "[dry-run] would patch $ConfigPath, regenerate compose, build smilecdr, and docker compose up -d"
        exit 0
    }
    if (-not (Test-Command "docker")) {
        Write-ErrExit "required command not found: docker"
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker info 1>$null 2>$null
    $dockerInfoExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($dockerInfoExit -ne 0) {
        Write-ErrExit "Docker is not running (docker info failed)"
    }

    $ports = @{
        FHIR_PORT       = $FhirPort
        FHIRWEB_PORT    = $FhirWebPort
        ADMIN_JSON_PORT = $AdminJsonPort
        ADMIN_WEB_PORT  = $AdminWebPort
        SMART_AUTH_PORT = $SmartAuthPort
        SMART_DEMO_PORT = $SmartDemoPort
    }
    Invoke-PortUpdates `
        -ConfigPath $ConfigPath `
        -ComposePath $ComposeFile `
        -PostgresTag $postgresTagFromCompose `
        -ProjectName $ProjectName `
        -ComposeEnvArgs $ComposeEnvArgs `
        -Ports $ports `
        -DbName $DbCdrName `
        -DbUser $DbCdrUser `
        -DbPassword $DbCdrPassword `
        -SmileVersion $SmileVersion `
        -Platform $SmilePlatform `
        -TemplatePath (Join-Path $DockerDir "compose.template.yml")

    Write-Host @"

Port settings from config.env are applied.

  Admin Web UI:  http://localhost:${AdminWebPort}
  FHIR endpoint: http://localhost:${FhirPort}
  FHIRWeb:       http://localhost:${FhirWebPort}
  Postgres:      localhost:${PostgresHostPort}

Follow SmileCDR logs:
  docker logs -f smilecdr-${SmileVersion}
"@
    exit 0
}

if ($DryRun) {
    Write-Host "[dry-run] would load image, patch config, build, and start the stack."
    exit 0
}

if (-not (Test-Command "docker")) {
    Write-ErrExit "required command not found: docker"
}

# Native docker.exe writes warnings to stderr; do not treat those as terminating errors.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
docker info 1>$null 2>$null
$dockerInfoExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($dockerInfoExit -ne 0) {
    Write-ErrExit "Docker is not running (docker info failed)"
}

if ($ForceLoad -or -not (Test-DockerImage $ImageTag)) {
    Write-Host "Loading Docker image from tarball (this can take several minutes)..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $loadOut = & docker image load --input $Tarball 2>&1 | Out-String
    $loadExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Write-Host $loadOut
    if ($loadExit -ne 0 -or -not (Test-DockerImage $ImageTag)) {
        Write-ErrExit "image $ImageTag not present after load"
    }
}
else {
    Write-Host "Image $ImageTag already present (use -ForceLoad to reload)."
}

Copy-Item -LiteralPath (Join-Path $DockerDir "init_postgresdb.sh") -Destination (Join-Path $RuntimeDir "init_postgresdb.sh") -Force
Copy-Item -LiteralPath (Join-Path $DockerDir "Dockerfile.postgres") -Destination (Join-Path $RuntimeDir "Dockerfile.postgres") -Force
Copy-Item -LiteralPath (Join-Path $DockerDir "Dockerfile.smilecdr") -Destination (Join-Path $RuntimeDir "Dockerfile.smilecdr") -Force

$dfPg = Get-Content -LiteralPath (Join-Path $RuntimeDir "Dockerfile.postgres") -Raw
$dfPg = $dfPg -replace 'ARG POSTGRES_TAG=.*', "ARG POSTGRES_TAG=$PostgresTag"
Write-TextFile -Path (Join-Path $RuntimeDir "Dockerfile.postgres") -Content $dfPg

$dfSm = Get-Content -LiteralPath (Join-Path $RuntimeDir "Dockerfile.smilecdr") -Raw
$dfSm = $dfSm -replace 'ARG SMILECDR_IMAGE=.*', "ARG SMILECDR_IMAGE=$ImageTag"
Write-TextFile -Path (Join-Path $RuntimeDir "Dockerfile.smilecdr") -Content $dfSm

$ConfigPath = Join-Path $RuntimeDir "cdr-config-Master.properties"
Write-Host "Extracting default cdr-config-Master.properties from $ImageTag..."
Get-ConfigFromImage -Image $ImageTag -Dest $ConfigPath

$ports = @{
    FHIR_PORT       = $FhirPort
    FHIRWEB_PORT    = $FhirWebPort
    ADMIN_JSON_PORT = $AdminJsonPort
    ADMIN_WEB_PORT  = $AdminWebPort
    SMART_AUTH_PORT = $SmartAuthPort
    SMART_DEMO_PORT = $SmartDemoPort
}
Update-SmileConfig -File $ConfigPath -DbName $DbCdrName -DbUser $DbCdrUser -DbPassword $DbCdrPassword -Ports $ports

Expand-ComposeTemplate `
    -Template (Join-Path $DockerDir "compose.template.yml") `
    -OutFile $ComposeFile `
    -Version $SmileVersion `
    -PostgresTag $PostgresTag `
    -Platform $SmilePlatform

Write-Host "Starting stack..."
$upCode = Invoke-Docker (@(
    "compose", "-f", $ComposeFile,
    "--project-name", $ProjectName
) + $ComposeEnvArgs + @("up", "-d", "--build"))
if ($upCode -ne 0) { exit $upCode }

Write-Host @"

Stack is starting.

  Admin Web UI:  http://localhost:${AdminWebPort}  (default admin / password)
  FHIR endpoint: http://localhost:${FhirPort}
  FHIRWeb:       http://localhost:${FhirWebPort}
  Postgres:      localhost:${PostgresHostPort}  (db/user ${DbCdrName}/${DbCdrUser})

Follow SmileCDR logs:
  docker logs -f smilecdr-${SmileVersion}

Stop the stack:
  powershell -File `"$($MyInvocation.MyCommand.Path)`" -Tarball `"$Tarball`" -Down
"@
