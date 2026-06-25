<#
	.Synopsis
	Snaffler output file parser
	.Description
	Split, sort and beautify the Snaffler output.
	Adds explorer++ integration for easy file and share browsing (runas /netonly support)
	.Parameter outformat
	Output options: 
		- all : write txt, csv, html and json
		- txt : write txt
		- csv : write csv
		- json : write json
		- html : write html
		- default : write txt, csv, html
	.Parameter in
	Single input file (full path or file name). Defaults to snafflerout.txt
	.Parameter ins
	Comma-separated list of input files e.g. -ins file1.log,file2.log
	.Parameter indir
	Directory containing Snaffler .log or .txt files to parse (all files loaded, duplicates removed)
	.Parameter domain
	Optional domain keyword (e.g. "CORP" or "contoso"). Boosts credScore when domain context
	is found alongside a credential: @domain, domain\user, *.domain.*, svc- accounts, etc.
	Score 1 = real cred, Score 2 = + domain context, Score 3 = + service account
	.Parameter sort
	Field to sort output:
		- modified: File modified date (default)
		- keyword: Snaffler keyword
		- unc: File UNC Path
	- rule: Snaffler rule name
	.Parameter split
	Will create splitted (by severity black, red, yellow, green) export files
	.Parameter gridview
	Analyze the file and display in PS gridview
	.Parameter gridviewload
	Switch to load an existing PS gridview output (CSV)
	.Parameter gridin
	Input file (full path or filename)
	Defaults to snafflerout.txt_loot_gridview.csv
	.Parameter pte
	pte (pass to explorer) exports the shares to Explorer++ as bookmarks (grouped by host)
	Explorer++ must be configured to be in Portable mode (settings saved in xml file) and only one instance is allowed.
	.Parameter snaffel
	Run Snaffler and execute parser with default settings.
	.Example
	.\snafflerparser.ps1 
	(will try to load snafflerout.txt and output in HTML, CSV and TXT format)
	.Example
	.\snafflerparser.ps1 -in mysnaffleroutput.tvs
	(will try to load mysnaffleroutput.tvs in HTML, CSV and TXT format)
	.Example
	.\snafflerparser.ps1 outformat csv -split
	(will store results as CSV and split the files by severity)
	.Example
	.\snafflerparser.ps1 -sort unc
	(will sort by the column unc)
	.Example
	.\snafflerparser.ps1 -gridview
	(Will  additionally show the output in PS Gridview and save the gridview for later use)
	.Example
	.\snafflerparser.ps1 -gridviewload
	(Load a existing gridview (defaults to snafflerout.txt_loot_gridview.csv))
	.Example
	.\snafflerparser.ps1 -gridviewload -gridin mygridviewfile.csv
	(Load specific gridview file)
	.Example
	.\snafflerparser.ps1 -pte
	(Add Shares as Bookmarks to explorer++)

	.LINK
	https://github.com/zh54321/snaffler_parser
#>
Param (
	[String]
	$in = '',
	[String[]]
	$ins = @(),
	[String]
	$indir = '',
	[ValidateSet("modified", "keyword", "rule", "unc")]
	[String]
	$sort = "modified",
	[ValidateSet("all", "csv", "txt", "json","html","default")]
	[String]
	$outformat = "default",
	[switch]
	$gridview,
	[switch]
	$gridviewload,
	[switch]
	$split,
	[String]
	$gridin = 'snafflerout.txt_loot_gridview.csv',
	[String]
	$exlorerpp = '.\Explorer++.exe',
	[switch]
	$pte,
	[String]
	$domain = '',
	[switch]
	$snaffel,
	[switch]
	$help,
	[switch]
	$h,
	[Alias("?")]
	[switch]
	$question
)

# Build the list of input files from -in, -ins, and/or -indir
$inputFiles = [System.Collections.Generic.List[string]]::new()

# -in: single file (backwards compat)
if ($in -ne '') {
    $p = if ([System.IO.Path]::IsPathRooted($in)) { $in } else { Join-Path (Get-Location) $in }
    $inputFiles.Add([System.IO.Path]::GetFullPath($p))
}

# -ins: array of files e.g. -ins file1.log,file2.log
foreach ($f in $ins) {
    if ([string]::IsNullOrWhiteSpace($f)) { continue }
    $p = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path (Get-Location) $f }
    $inputFiles.Add([System.IO.Path]::GetFullPath($p))
}

# -indir: all .log/.txt files in a directory
if ($indir -ne '') {
    $dirPath = if ([System.IO.Path]::IsPathRooted($indir)) { $indir } else { Join-Path (Get-Location) $indir }
    $dirPath = [System.IO.Path]::GetFullPath($dirPath)
    if (Test-Path -LiteralPath $dirPath -PathType Container) {
        Get-ChildItem -LiteralPath $dirPath -File | Where-Object { $_.Extension -in '.log','.txt' } |
            ForEach-Object { $inputFiles.Add($_.FullName) }
    } else {
        write-host "[-] Directory not found: $dirPath"
        exit
    }
}

# Fallback: no inputs specified - use original default
if ($inputFiles.Count -eq 0) {
    $p = Join-Path (Get-Location) 'snafflerout.txt'
    $inputFiles.Add([System.IO.Path]::GetFullPath($p))
}

# Deduplicate the file list itself
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$inputFiles = $inputFiles | Where-Object { $seen.Add($_) }

# $inPath kept for single-file compat references
$inPath = $inputFiles[0]


# Function section-----------------------------------------------------------------------------------

function Format-TimePrettyUtc {
    param([object]$value)

    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return "" }

    try {
        switch ($value.GetType().FullName) {
            'System.DateTimeOffset' { return $value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'") }
            'System.DateTime'       { return ([DateTime]$value).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'") }
            default {
                # Try to parse string as DateTimeOffset first (handles Z nicely)
                $dto = [DateTimeOffset]::Parse(
                    [string]$value,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal
                )
                return $dto.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
            }
        }
    } catch {
        # If parsing fails, just return original string
        return [string]$value
    }
}

function Format-DurationPretty {
    param([object]$ts)

    if ($null -eq $ts) { return "" }
    try { $ts = [TimeSpan]$ts } catch { return "" }

    $parts = @()

    if ($ts.Days    -gt 0) { $parts += "$($ts.Days)d" }
    if ($ts.Hours   -gt 0) { $parts += "$($ts.Hours)h" }
    if ($ts.Minutes -gt 0) { $parts += "$($ts.Minutes)m" }

    # Round to whole seconds (0.5s rounds up)
    $totalSecondsRounded = [int][math]::Round($ts.TotalSeconds, 0, [MidpointRounding]::AwayFromZero)

    if ($parts.Count -gt 0) {
        # show remaining seconds within the minute (also whole)
        $secWithinMinute = $totalSecondsRounded % 60
        $parts += ("{0}s" -f $secWithinMinute)
    } else {
        # only seconds (whole)
        $parts += ("{0}s" -f $totalSecondsRounded)
    }

    return ($parts -join " ")
}



# -------------------------------------------------------------------------
# Get-CredScore: 0-100 confidence score for plaintext credentials in content.
#
# Score guide:
#   0        = no signal
#   5-10     = credential terms mentioned, no values / reference only
#   15-20    = encrypted/indirect read (Get-Content|ConvertTo-SecureString)
#   18-25    = connection string, no cleartext password
#   75       = real plaintext credential value found
#   85-90    = real cred + high-confidence token / common password / connstr
#   87       = ConvertTo-SecureString -AsPlainText -Force (cleartext embedded)
#   90+      = known token prefix (ghp_, AKIA, eyJ, etc.)
#   95       = username + password pair together
#  ~100      = username + password + domain context
# -------------------------------------------------------------------------
function Get-CredScore {
    param(
        [string]$text,
        [string]$domainHint = '',
        [string]$uncPath = ''
    )

    # Always-100 override: confcons.xml is a known high-value credential store
    # regardless of content (e.g. encrypted/binary content Snaffler can't preview).
    if ($uncPath -and ([System.IO.Path]::GetFileName($uncPath) -ieq 'confcons.xml')) {
        return 100
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return 0 }

    # Unescape Snaffler escape sequences
    $t = $text -replace '\\r\\n',"`n" -replace '\\n',"`n" -replace '\\t',"`t" -replace '\\ ',' '
    $t = $t -replace '\\([(){}[\].\$\*\+\?\^|/\\-])', '$1'
    # Decode HTML entities that appear in connection strings
    $t = $t -replace '&quot;','"' -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
    # Unescape remaining backslash-escaped non-alpha chars (e.g. \# -> #, \$ -> $)
    $t = $t -replace '\\([^a-zA-Z0-9\\])','$1'

    # ── ConvertTo-SecureString "VALUE" -AsPlainText -Force = cleartext ────────
    $PLAINTEXT_SS = [regex]'(?i)ConvertTo-SecureString\s+["'']([^"'']{4,})["'']\s+-AsPlainText\s+-Force'
    $ptssMatch = $PLAINTEXT_SS.Match($t)
    $hasPtss = $ptssMatch.Success

    # Strip the -AsPlainText form before checking encrypted reads
    $tNoPlain = $PLAINTEXT_SS.Replace($t, '')

    # ── Encrypted/indirect credential reads ───────────────────────────────────
    $ENCRYPTED_READ = (
        ($tNoPlain -imatch 'get-content\b[^|]*\|\s*convertto-securestring') -or
        ($tNoPlain -imatch '\bconvertfrom-securestring\b') -or
        ($tNoPlain -imatch '\bread-host\b.*-assecurestring')
    )

    # ── Reference-only patterns (no hardcoded value) ──────────────────────────
    $REFERENCE_ONLY = (
        ($t -imatch '\bget-credential\b') -or
        ($t -imatch '\-savedcred\b')
    )

    # ── Known high-confidence token prefixes ─────────────────────────────────
    $TOKEN_PREFIX_RE = [regex]'^(ghp_|ghs_|gho_|github_pat_|glpat-|xox[bpas]-|sk-[A-Za-z0-9]{20,}|pk_|rk_live_|AKIA|AIPA|AIDA|AROA|ANPA|ANVA|ASIA|eyJ)'

    # ── Common weak password patterns ─────────────────────────────────────────
    $COMMON_PASS_RE = [regex]'(?i)\b(spring|summer|autumn|fall|winter|welcome|password|p@ss|pass123|admin|letmein|qwerty|abc123|111111|changeme|default|temp\d{2,4}|test\d{2,4})\d{0,4}[!@#$%^&*]?\b'

    # ── Credential field = value regex ────────────────────────────────────────
    $CRED_FIELD_RE = [regex]('(?:^|[\s,;{(\r\n])(password|passwd|passw|strpassword|secret|' +
        'api[-_.]?key|apitoken|access[-_.]?(?:key|token)|auth[-_.]?token|' +
        'client[-_.]?secret|private[-_.]?key|token|pwd|pword)' +
        '\s*[=:]\s*["'']?([^\s"''' + '`\r\n<>,;{}()\]\\]{4,})["'']?')

    # ── Username presence ─────────────────────────────────────────────────────
    $USERNAME_RE = [regex]'(?i)(?:^|[\s,;{(\r\n])(username|user[\s_]?id|userid|uid|login|struser|user\s*=|uid\s*=|user\s+id\s*=)\s*[=:]\s*["'']?([^\s"''<>$]{3,})["'']?'

    # ── Connection string patterns ────────────────────────────────────────────
    $CONNSTR_RE    = [regex]'(?i)\b(connectionstring|server\s*=|database\s*=|jdbc:|odbc:|user\s*id\s*=|integrated\s*security)'
    $CONNSTR_PASS_RE = [regex]'(?i)Password\s*=\s*(?![\s"'']*(true|false|\{|\$|get-|read-|convert|%\(|\{\{|your|change|<|;|password\b)|\$)[^\s;,''"\\&]{4,}'

    # ── Domain context regex (if hint provided) ───────────────────────────────
    $domainRe = $null
    if (-not [string]::IsNullOrWhiteSpace($domainHint)) {
        $esc = [regex]::Escape($domainHint.Trim())
        $domainRe = [regex]"(?i)(@${esc}\b|${esc}[\\\/]\w|[*\w][.-]${esc}[.-]|\b${esc}[\\\/])"
    }

    # ── Helper: is this a real credential value (not a var/placeholder)? ──────
    function IsRealValue([string]$val) {
        if (-not $val -or $val.Length -lt 4) { return $false }
        $v = $val.Trim()
        # Variables, templates, PS constructs
        if ($v -imatch '^(\$|%\(|\{\{|@\{|\[<|\[System\.|true$|false$|null$|none$|undefined$|get-|read-|convert)') { return $false }
        if ($v -imatch '^%[({]') { return $false }
        # Pure camelCase identifier with no digits = variable name like clientSecret
        if ($v -cmatch '^[a-z][a-zA-Z]{2,}$') { return $false }
        # Common placeholder words
        if ($v -imatch '^(password|passwd|secret|changeme|yourpassword|example|test|demo|dummy|placeholder|token|admin|login|user|username)$') { return $false }
        if ($v -imatch '\b(your|my|enter|replace|sample|placeholder|todo|fixme|here)\b') { return $false }
        return $true
    }

    # ── Helper: does value have real-password complexity? ────────────────────
    function HasComplexity([string]$val) {
        if ($TOKEN_PREFIX_RE.IsMatch($val)) { return $true }
        if ($COMMON_PASS_RE.IsMatch($val))  { return $true }
        # % prefix like %UGscr85An
        if ($val -cmatch '^%[A-Za-z0-9]{4,}') { return $true }
        $c = 0
        if ($val -cmatch '[A-Z]')        { $c++ }
        if ($val -cmatch '[a-z]')        { $c++ }
        if ($val -match '\d')            { $c++ }
        if ($val -match '[^a-zA-Z0-9]') { $c++ }
        if ($val.Length -ge 8)          { $c++ }
        return $c -ge 3
    }

    # ── Collect real credential pairs ─────────────────────────────────────────
    $realPairs = [System.Collections.Generic.List[hashtable]]::new()
    $credMatches = $CRED_FIELD_RE.Matches($t)
    foreach ($cm in $credMatches) {
        $field = $cm.Groups[1].Value
        $val   = $cm.Groups[2].Value.Trim('"', "'")
        if ((IsRealValue $val) -and (HasComplexity $val)) {
            $realPairs.Add(@{ field = $field; val = $val })
        }
    }

    # ── JSON "name":"CRED_FIELD","value":"REAL_VALUE" pattern ────────────────
    # Catches Postman/Azure DevOps/appsettings JSON env-var style credentials
    $JSON_CRED_RE = [regex]'(?i)"name"\s*:\s*"([^"]*(?:secret|password|passwd|api[_-]?key|token|client[_-]?secret|access[_-]?key|client[_-]?id)[^"]*)"\s*[\s\S]{0,300}?"value"\s*:\s*"([^"]{4,})"'
    $jsonMatches = $JSON_CRED_RE.Matches($t)
    foreach ($jm in $jsonMatches) {
        $field = $jm.Groups[1].Value
        $val   = $jm.Groups[2].Value
        if ((IsRealValue $val) -and (HasComplexity $val)) {
            $realPairs.Add(@{ field = $field; val = $val })
        }
    }

    # ── XML appSettings key="CRED_FIELD" value="REAL_VALUE" pattern ──────────
    # Catches: <add key="password" value="ta8@TAfuQap6a7es" />
    # Also:    <add key="ApiKey" value="abc123..." />
    $XML_KV_RE = [regex]'(?i)key\s*=\s*["''](?:[^"'']*[-_.])?(?:password|passwd|secret|api[-_.]?key|apikey|(?:access|auth|bearer|id|refresh|session|api)?[-_.]?token|client[-_.]?secret|access[-_.]?key)(?:[-_.][^"'']*)?["'']\s+value\s*=\s*["'']([^"'']{4,})["'']'
    $hasXmlCred = $false
    $xmlKvMatches = $XML_KV_RE.Matches($t)
    foreach ($xm in $xmlKvMatches) {
        $field = $xm.Groups[1].Value
        $val   = $xm.Groups[2].Value
        if ((IsRealValue $val) -and (HasComplexity $val)) {
            $realPairs.Add(@{ field = $field; val = $val })
            $hasXmlCred = $true
        }
    }

    # Add -AsPlainText plaintext as a real pair
    if ($hasPtss) {
        $ptssVal = $ptssMatch.Groups[1].Value
        $realPairs.Add(@{ field = 'plaintext-securestring'; val = $ptssVal })
    }

    $hasUsername    = $USERNAME_RE.IsMatch($t) -or ($t -imatch 'User\s+ID\s*=\s*\S{3,}') -or ($t -imatch '"name"\s*:\s*"[^"]*client[_-]?id[^"]*"')
    $hasConnStrPass = $CONNSTR_PASS_RE.IsMatch($t)
    $hasDomainCtx   = ($null -ne $domainRe -and $domainRe.IsMatch($t)) -or
                      ($t -match '\\\\[\w\-\.]+\\[\w\-\.\$]+') -or
                      ($t -match '@[\w\-]+\.[\w\-]+') -or
                      ($t -imatch '\b\w{2,15}\\{1,2}\w{2,30}\b')

    $SVC_RE = [regex]'(?i)(^|[\\/\s@])s(?:vc|ervice)?[-_]|[-_]s(?:vc|ervice)?(?:acct|account)?($|[\\/\s@])|[\\/]svc[\\/\s]|(?:^|[\\/\s])sa[-_]|s-1-5-'
    $hasSvcCtx = $SVC_RE.IsMatch($t) -or (
        $null -ne $domainRe -and $domainRe.IsMatch($t) -and ($t -imatch '(svc|service.acct|serviceaccount|\bsa[-_])'))

    # ── Score computation ─────────────────────────────────────────────────────
    $score = 0

    # hasConnStrPass = real plaintext Password= found in connection string.
    # Promote it to a realPair so it always scores high even if CRED_FIELD_RE missed it.
    if ($hasConnStrPass -and $realPairs.Count -eq 0) {
        $realPairs.Add(@{ field = 'connstr-password'; val = 'connstr' })
    }
    # XML cred also boosts like a connection string password
    if ($hasXmlCred) { $hasConnStrPass = $true }

    if ($realPairs.Count -gt 0) {
        $score = if ($hasPtss) { 87 } else { 75 }
        if ($hasUsername)                    { $score = 95 }
        if ($hasConnStrPass)                 { $score = [Math]::Max($score, 88) }
        if ($hasUsername -and $hasConnStrPass) { $score = 97 }
        if ($realPairs | Where-Object { $COMMON_PASS_RE.IsMatch($_.val) }) { $score = [Math]::Max($score, 85) }
        if ($realPairs | Where-Object { $TOKEN_PREFIX_RE.IsMatch($_.val) }) { $score = [Math]::Max($score, 90) }
        if ($hasDomainCtx -and $score -lt 95) { $score = [Math]::Min($score + 5, 94) }
        if ($hasSvcCtx -and $hasDomainCtx -and $score -lt 99) { $score = [Math]::Min($score + 4, 99) }
        if ($ENCRYPTED_READ -and -not $hasPtss) { $score = [Math]::Min($score, 60) }

    } elseif ($REFERENCE_ONLY) {
        $score = 5

    } elseif ($ENCRYPTED_READ) {
        $score = if ($hasUsername) { 20 } else { 15 }

    } elseif ($CONNSTR_RE.IsMatch($t)) {
        $score = if ($t -imatch 'integrated\s*security\s*=\s*(true|sspi)') { 18 } else { 25 }

    } else {
        $credMention = $t -imatch '(password|secret|credential|apikey|token)'
        $score = if ($credMention) { 8 } else { 0 }
    }
    $finalScore = [Math]::Min(100, [Math]::Max(0, $score))
    # Debug: print what triggered high scores
    if ($finalScore -ge 90 -and $env:SNAFFLER_DEBUG -eq '1') {
        Write-Host "[DEBUG score=$finalScore] realPairs=$($realPairs.Count) hasConnStrPass=$hasConnStrPass hasUsername=$hasUsername hasPtss=$hasPtss hasXmlCred=$hasXmlCred"
        foreach ($p in $realPairs) { Write-Host "  [DEBUG pair] field=$($p.field) val=$($p.val.Substring(0,[Math]::Min(40,$p.val.Length)))" }
        Write-Host "  [DEBUG text excerpt] $($t.Substring(0,[Math]::Min(120,$t.Length)))"
    }
    return $finalScore
}



function gridview($action){
	if ($action -eq "load") {
		write-host "[*] Loading stored Gridview file: $($gridin)"
		if (!(Test-Path -LiteralPath $inpath -PathType Leaf)) {
			write-host "[-] Input file not found $($gridin) use -gridin to specify the file csv"
			exit
		}
		write-host "[*] Starting Gridview (opens in background)"
		$passthruobjec = Import-Csv -Path "$($gridin)" |  Out-GridView -Title "FullView" -PassThru

	} elseif ($action -eq "start") {
		write-host "[*] Writing Gridview output file for further use"
		$fulloutput | select-object severity,rule,keyword,modified,extension,unc,content | Export-Csv -Path "$($outputname)_loot_gridview.csv" -NoTypeInformation
		write-host "[*] Starting Gridview (opens in background)"
		$passthruobjec = $fulloutput | select-object severity,rule,keyword,modified,extension,unc,content |  Out-GridView -Title "FullView" -PassThru
	}
	$countpassthruobjec = $passthruobjec | Measure-Object -Line -Property unc
	if ($countpassthruobjec.lines -ge 1) {
		if (!(Test-Path -Path $exlorerpp -PathType Leaf)) {
			write-host "[-] Explorer++ not found at $exlorerpp use -explorerpp to specify the exe file"
			exit
		} else {
			write-host "[-] Explorer++ found at $exlorerpp"
			write-host "[*] Found $($countpassthruobjec.lines) object. Trying to open them in Explorer++ "
			write-host "[i] Start the script in console window runas ... /netonly to access the files as different user"
			write-host "[i] Disables the 'Allow multiple instance' in Explorer++ to open multiple location in tabs "
			foreach ($path in $passthruobjec.unc) {
				$pathtoopen = (Split-Path -Path $path -Parent)
				# Danger danger Invoke-Expression
				& $exlorerpp $pathtoopen
				Start-Sleep -Milliseconds 500
			}
		}
	} else {
		write-host "[!] No PassThru object found"
	}
	write-host "[*] Exiting"
	exit
}


function explorerpp($objects) {

    $explorerppfolder = Split-Path $exlorerpp
    $configPath = Join-Path $explorerppfolder "config.xml"

    # If exlorerpp is ".\Explorer++.exe", Split-Path returns "."
    if ($explorerppfolder -eq ".") {
        $configPath = Join-Path $pwd "config.xml"
    }

    # -----------------------------
    # Default config.xml template
    # -----------------------------
    $defaultConfig = @'
<?xml version="1.0"?>
<!-- Preference file for Explorer++ generated by Snafflerparser-->
<ExplorerPlusPlus>
	<Settings>
		<Setting name="AllowMultipleInstances">yes</Setting>
		<Setting name="AlwaysOpenInNewTab">no</Setting>
		<Setting name="AlwaysShowTabBar">yes</Setting>
		<Setting name="AutoArrangeGlobal">yes</Setting>
		<Setting name="CheckBoxSelection">no</Setting>
		<Setting name="CloseMainWindowOnTabClose">yes</Setting>
		<Setting name="ConfirmCloseTabs">no</Setting>
		<Setting name="DisableFolderSizesNetworkRemovable">no</Setting>
		<Setting name="DisplayCentreColor" r="255" g="255" b="255"/>
		<Setting name="DisplayFont" Height="-13" Width="0" Weight="500" Italic="no" Underline="no" Strikeout="no" Font="Segoe UI"/>
		<Setting name="DisplaySurroundColor" r="0" g="94" b="138"/>
		<Setting name="DisplayTextColor" r="0" g="0" b="0"/>
		<Setting name="DisplayWindowWidth">300</Setting><Setting name="DisplayWindowHeight">90</Setting>
		<Setting name="DisplayWindowVertical">no</Setting>
		<Setting name="DoubleClickTabClose">yes</Setting>
		<Setting name="ExtendTabControl">no</Setting>
		<Setting name="ForceSameTabWidth">no</Setting>
		<Setting name="ForceSize">no</Setting>
		<Setting name="HandleZipFiles">no</Setting>
		<Setting name="HideLinkExtensionGlobal">no</Setting>
		<Setting name="HideSystemFilesGlobal">no</Setting>
		<Setting name="InfoTipType">0</Setting>
		<Setting name="InsertSorted">yes</Setting>
		<Setting name="Language">9</Setting>
		<Setting name="LargeToolbarIcons">no</Setting>
		<Setting name="LastSelectedTab">0</Setting>
		<Setting name="LockToolbars">yes</Setting>
		<Setting name="NextToCurrent">no</Setting>
		<Setting name="NewTabDirectory">::{20D04FE0-3AEA-1069-A2D8-08002B30309D}</Setting>
		<Setting name="OneClickActivate">no</Setting>
		<Setting name="OneClickActivateHoverTime">500</Setting>
		<Setting name="OverwriteExistingFilesConfirmation">yes</Setting>
		<Setting name="PlayNavigationSound">yes</Setting>
		<Setting name="ReplaceExplorerMode">1</Setting>
		<Setting name="ShowAddressBar">yes</Setting>
		<Setting name="ShowApplicationToolbar">yes</Setting>
		<Setting name="ShowBookmarksToolbar">yes</Setting>
		<Setting name="ShowDrivesToolbar">yes</Setting>
		<Setting name="ShowDisplayWindow">yes</Setting>
		<Setting name="ShowExtensions">yes</Setting>
		<Setting name="ShowFilePreviews">yes</Setting>
		<Setting name="ShowFolders">yes</Setting>
		<Setting name="ShowFolderSizes">no</Setting>
		<Setting name="ShowFriendlyDates">yes</Setting>
		<Setting name="ShowFullTitlePath">no</Setting>
		<Setting name="ShowGridlinesGlobal">yes</Setting>
		<Setting name="ShowHiddenGlobal">yes</Setting>
		<Setting name="ShowInfoTips">yes</Setting>
		<Setting name="ShowInGroupsGlobal">no</Setting>
		<Setting name="ShowPrivilegeLevelInTitleBar">no</Setting>
		<Setting name="ShowStatusBar">yes</Setting>
		<Setting name="ShowTabBarAtBottom">no</Setting>
		<Setting name="ShowTaskbarThumbnails">yes</Setting>
		<Setting name="ShowToolbar">yes</Setting>
		<Setting name="ShowUserNameTitleBar">no</Setting>
		<Setting name="SizeDisplayFormat">1</Setting>
		<Setting name="SortAscendingGlobal">yes</Setting>
		<Setting name="StartupMode">1</Setting>
		<Setting name="SynchronizeTreeview">yes</Setting>
		<Setting name="TVAutoExpandSelected">no</Setting>
		<Setting name="UseFullRowSelect">no</Setting>
		<Setting name="IconTheme">0</Setting>
		<Setting name="ToolbarState" Button0="Back" Button1="Forward" Button2="Up" Button3="Separator" Button4="Folders" Button5="Separator" Button6="Cut" Button7="Copy" Button8="Paste" Button9="Delete" Button10="Delete Permanently" Button11="Properties" Button12="Search" Button13="Separator" Button14="New Folder" Button15="Copy To" Button16="Move To" Button17="Separator" Button18="Views" Button19="Open Command Prompt" Button20="Refresh" Button21="Separator" Button22="Bookmark the current tab" Button23="Organize Bookmarks"/>
		<Setting name="TreeViewDelayEnabled">no</Setting>
		<Setting name="TreeViewWidth">208</Setting>
		<Setting name="ViewModeGlobal">1</Setting>
	</Settings>
	<WindowPosition>
		<Setting name="Position" Flags="0" ShowCmd="1" MinPositionX="0" MinPositionY="0" MaxPositionX="-1" MaxPositionY="-1" NormalPositionLeft="68" NormalPositionTop="64" NormalPositionRight="3368" NormalPositionBottom="1113"/>
	</WindowPosition>
	<Tabs>
		<Tab name="0" Directory="::{20D04FE0-3AEA-1069-A2D8-08002B30309D}" ApplyFilter="no" AutoArrange="yes" Filter="" FilterCaseSensitive="no" ShowHidden="yes" ShowInGroups="no" SortAscending="yes" SortMode="1" ViewMode="1" Locked="no" AddressLocked="no" UseCustomName="no" CustomName="">
			<Columns>
				<Column name="Generic" Name="yes" Name_Width="150" Type="yes" Type_Width="150" Size="yes" Size_Width="150" DateModified="yes" DateModified_Width="150" Attributes="no" Attributes_Width="150" SizeOnDisk="no" SizeOnDisk_Width="150" ShortName="no" ShortName_Width="150" Owner="no" Owner_Width="150" ProductName="no" ProductName_Width="150" Company="no" Company_Width="150" Description="no" Description_Width="150" FileVersion="no" FileVersion_Width="150" ProductVersion="no" ProductVersion_Width="150" ShortcutTo="no" ShortcutTo_Width="150" HardLinks="no" HardLinks_Width="150" Extension="no" Extension_Width="150" Created="no" Created_Width="150" Accessed="no" Accessed_Width="150" Title="no" Title_Width="150" Subject="no" Subject_Width="150" Author="no" Author_Width="150" Keywords="no" Keywords_Width="150" Comment="no" Comment_Width="150" CameraModel="no" CameraModel_Width="150" DateTaken="no" DateTaken_Width="150" Width="no" Width_Width="150" Height="no" Height_Width="150" MediaBitrate="no" MediaBitrate_Width="150" MediaCopyright="no" MediaCopyright_Width="150" MediaDuration="no" MediaDuration_Width="150" MediaProtected="no" MediaProtected_Width="150" MediaRating="no" MediaRating_Width="150" MediaAlbumArtist="no" MediaAlbumArtist_Width="150" MediaAlbum="no" MediaAlbum_Width="150" MediaBeatsPerMinute="no" MediaBeatsPerMinute_Width="150" MediaComposer="no" MediaComposer_Width="150" MediaConductor="no" MediaConductor_Width="150" MediaDirector="no" MediaDirector_Width="150" MediaGenre="no" MediaGenre_Width="150" MediaLanguage="no" MediaLanguage_Width="150" MediaBroadcastDate="no" MediaBroadcastDate_Width="150" MediaChannel="no" MediaChannel_Width="150" MediaStationName="no" MediaStationName_Width="150" MediaMood="no" MediaMood_Width="150" MediaParentalRating="no" MediaParentalRating_Width="150" MediaParentalRatingReason="no" MediaParentalRatingReason_Width="150" MediaPeriod="no" MediaPeriod_Width="150" MediaProducer="no" MediaProducer_Width="150" MediaPublisher="no" MediaPublisher_Width="150" MediaWriter="no" MediaWriter_Width="150" MediaYear="no" MediaYear_Width="150"/>
				<Column name="MyComputer" Name="yes" Name_Width="150" Type="yes" Type_Width="150" TotalSize="yes" TotalSize_Width="150" FreeSpace="yes" FreeSpace_Width="150" VirtualComments="no" VirtualComments_Width="150" FileSystem="no" FileSystem_Width="150"/>
				<Column name="ControlPanel" Name="yes" Name_Width="150" VirtualComments="yes" VirtualComments_Width="150"/>
				<Column name="RecycleBin" Name="yes" Name_Width="150" OriginalLocation="yes" OriginalLocation_Width="150" DateDeleted="yes" DateDeleted_Width="150" Size="yes" Size_Width="150" Type="yes" Type_Width="150" DateModified="yes" DateModified_Width="150"/>
				<Column name="Printers" Name="yes" Name_Width="150" Documents="yes" Documents_Width="150" Status="yes" Status_Width="150" PrinterComments="yes" PrinterComments_Width="150" PrinterLocation="yes" PrinterLocation_Width="150" PrinterModel="yes" PrinterModel_Width="150"/>
				<Column name="Network" Name="yes" Name_Width="150" Type="yes" Type_Width="150" NetworkAdaptorStatus="yes" NetworkAdaptorStatus_Width="150" Owner="yes" Owner_Width="150"/>
				<Column name="NetworkPlaces" Name="yes" Name_Width="150" VirtualComments="yes" VirtualComments_Width="150"/>
			</Columns>
		</Tab>
	</Tabs>
	<DefaultColumns>
		<Column name="Generic" Name="yes" Name_Width="150" Type="yes" Type_Width="150" Size="yes" Size_Width="150" DateModified="yes" DateModified_Width="150" Attributes="no" Attributes_Width="150" SizeOnDisk="no" SizeOnDisk_Width="150" ShortName="no" ShortName_Width="150" Owner="no" Owner_Width="150" ProductName="no" ProductName_Width="150" Company="no" Company_Width="150" Description="no" Description_Width="150" FileVersion="no" FileVersion_Width="150" ProductVersion="no" ProductVersion_Width="150" ShortcutTo="no" ShortcutTo_Width="150" HardLinks="no" HardLinks_Width="150" Extension="no" Extension_Width="150" Created="no" Created_Width="150" Accessed="no" Accessed_Width="150" Title="no" Title_Width="150" Subject="no" Subject_Width="150" Author="no" Author_Width="150" Keywords="no" Keywords_Width="150" Comment="no" Comment_Width="150" CameraModel="no" CameraModel_Width="150" DateTaken="no" DateTaken_Width="150" Width="no" Width_Width="150" Height="no" Height_Width="150" MediaBitrate="no" MediaBitrate_Width="150" MediaCopyright="no" MediaCopyright_Width="150" MediaDuration="no" MediaDuration_Width="150" MediaProtected="no" MediaProtected_Width="150" MediaRating="no" MediaRating_Width="150" MediaAlbumArtist="no" MediaAlbumArtist_Width="150" MediaAlbum="no" MediaAlbum_Width="150" MediaBeatsPerMinute="no" MediaBeatsPerMinute_Width="150" MediaComposer="no" MediaComposer_Width="150" MediaConductor="no" MediaConductor_Width="150" MediaDirector="no" MediaDirector_Width="150" MediaGenre="no" MediaGenre_Width="150" MediaLanguage="no" MediaLanguage_Width="150" MediaBroadcastDate="no" MediaBroadcastDate_Width="150" MediaChannel="no" MediaChannel_Width="150" MediaStationName="no" MediaStationName_Width="150" MediaMood="no" MediaMood_Width="150" MediaParentalRating="no" MediaParentalRating_Width="150" MediaParentalRatingReason="no" MediaParentalRatingReason_Width="150" MediaPeriod="no" MediaPeriod_Width="150" MediaProducer="no" MediaProducer_Width="150" MediaPublisher="no" MediaPublisher_Width="150" MediaWriter="no" MediaWriter_Width="150" MediaYear="no" MediaYear_Width="150"/>
		<Column name="MyComputer" Name="yes" Name_Width="150" Type="yes" Type_Width="150" TotalSize="yes" TotalSize_Width="150" FreeSpace="yes" FreeSpace_Width="150" VirtualComments="no" VirtualComments_Width="150" FileSystem="no" FileSystem_Width="150"/>
		<Column name="ControlPanel" Name="yes" Name_Width="150" VirtualComments="yes" VirtualComments_Width="150"/>
		<Column name="RecycleBin" Name="yes" Name_Width="150" OriginalLocation="yes" OriginalLocation_Width="150" DateDeleted="yes" DateDeleted_Width="150" Size="yes" Size_Width="150" Type="yes" Type_Width="150" DateModified="yes" DateModified_Width="150"/>
		<Column name="Printers" Name="yes" Name_Width="150" Documents="yes" Documents_Width="150" Status="yes" Status_Width="150" PrinterComments="yes" PrinterComments_Width="150" PrinterLocation="yes" PrinterLocation_Width="150" PrinterModel="yes" PrinterModel_Width="150"/>
		<Column name="Network" Name="yes" Name_Width="150" Type="yes" Type_Width="150" NetworkAdaptorStatus="yes" NetworkAdaptorStatus_Width="150" Owner="yes" Owner_Width="150"/>
		<Column name="NetworkPlaces" Name="yes" Name_Width="150" VirtualComments="yes" VirtualComments_Width="150"/>
	</DefaultColumns>
	<Bookmarksv2>
		<PermanentItem name="BookmarksToolbar" DateCreatedLow="1671045276" DateCreatedHigh="31227119" DateModifiedLow="1671045276" DateModifiedHigh="31227119">
		</PermanentItem>
		<PermanentItem name="BookmarksMenu" DateCreatedLow="1671045276" DateCreatedHigh="31227119" DateModifiedLow="1671045276" DateModifiedHigh="31227119">
		</PermanentItem>
		<PermanentItem name="OtherBookmarks" DateCreatedLow="1671045276" DateCreatedHigh="31227119" DateModifiedLow="1671045276" DateModifiedHigh="31227119">
		</PermanentItem>
	</Bookmarksv2>
	<ApplicationToolbar>
		<ApplicationButton name="Notepad" Command="C:\Windows\System32\notepad.exe" ShowNameOnToolbar="yes"/>
		<ApplicationButton name="Notepad++" Command="&quot;C:\Program Files\Notepad++\notepad++.exe&quot;" ShowNameOnToolbar="yes"/>
	</ApplicationToolbar>
	<Toolbars>
		<Toolbar name="0" id="0" Style="769" Length="604"/>
		<Toolbar name="1" id="1" Style="257" Length="0"/>
		<Toolbar name="2" id="2" Style="769" Length="0"/>
		<Toolbar name="3" id="3" Style="769" Length="84"/>
		<Toolbar name="4" id="4" Style="777" Length="0"/>
	</Toolbars>
	<ColorRules>
		<ColorRule name="Compressed files" FilenamePattern="" CaseInsensitive="no" Attributes="2048" r="0" g="0" b="255"/>
		<ColorRule name="Encrypted files" FilenamePattern="" CaseInsensitive="no" Attributes="16384" r="0" g="128" b="0"/>
	</ColorRules>
	<State>
	</State>
</ExplorerPlusPlus>
'@

    # -----------------------------
    # Load or create config.xml
    # -----------------------------
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Host "[*] Explorer++ config.xml not found. Creating default at: $configPath"
        $defaultConfig | Out-File -FilePath $configPath -Encoding UTF8
    } else {
        Write-Host "[*] Found Explorer++ config.xml: $configPath"
    }

    # Load XML
    try {
        $xmlfile = [xml](Get-Content -LiteralPath $configPath)
    } catch {
        Write-Host "[-] Failed to read XML at $configPath"
        Write-Host "    $($_.Exception.Message)"
        exit
    }

    # -----------------------------
    # Ensure Settings/ShowBookmarksToolbar=yes
    # -----------------------------
    $settingsNode = $xmlfile.SelectSingleNode("/ExplorerPlusPlus/Settings")
    if (-not $settingsNode) {
        $settingsNode = $xmlfile.CreateElement("Settings")
        [void]$xmlfile.ExplorerPlusPlus.AppendChild($settingsNode)
    }

    $showBm = $xmlfile.SelectSingleNode("/ExplorerPlusPlus/Settings/Setting[@name='ShowBookmarksToolbar']")
    if (-not $showBm) {
        $showBm = $xmlfile.CreateElement("Setting")
        [void]$showBm.SetAttribute("name", "ShowBookmarksToolbar")
        $showBm.InnerText = "yes"
        [void]$settingsNode.AppendChild($showBm)
        Write-Host "[*] Added Setting ShowBookmarksToolbar=yes"
    } else {
        if ($showBm.InnerText -ne "yes") {
            $showBm.InnerText = "yes"
            Write-Host "[*] Updated Setting ShowBookmarksToolbar=yes"
        }
    }

    # -----------------------------
    # Ensure Bookmarksv2 + BookmarksToolbar node exists
    # -----------------------------
    $bmRoot = $xmlfile.SelectSingleNode("/ExplorerPlusPlus/Bookmarksv2")
    if (-not $bmRoot) {
        $bmRoot = $xmlfile.CreateElement("Bookmarksv2")
        [void]$xmlfile.ExplorerPlusPlus.AppendChild($bmRoot)
    }

    $toolbarNode = $xmlfile.SelectSingleNode("/ExplorerPlusPlus/Bookmarksv2/PermanentItem[@name='BookmarksToolbar']")
    if (-not $toolbarNode) {
        $toolbarNode = $xmlfile.CreateElement("PermanentItem")
        [void]$toolbarNode.SetAttribute("name", "BookmarksToolbar")
        # Minimal timestamps (Explorer++ seems fine with any ints; keeping your style)
        [void]$toolbarNode.SetAttribute("DateCreatedLow", "3561811627")
        [void]$toolbarNode.SetAttribute("DateCreatedHigh", "3561811627")
        [void]$toolbarNode.SetAttribute("DateModifiedLow", "3561811627")
        [void]$toolbarNode.SetAttribute("DateModifiedHigh", "3561811627")
        [void]$bmRoot.AppendChild($toolbarNode)
        Write-Host "[*] Created BookmarksToolbar container"
    }

    # -----------------------------
    # Delete existing bookmarks ONLY under BookmarksToolbar
    # -----------------------------
    Write-Host "[*] Deleting existing bookmarks in BookmarksToolbar"
    $existing = $toolbarNode.SelectNodes("./Bookmark")
    foreach ($node in @($existing)) {
        [void]$toolbarNode.RemoveChild($node)
    }

    # -----------------------------
    # Add new bookmarks grouped by host
    # -----------------------------
    $counteruncstats = 0
    $counterhosts    = 0

    # We'll keep folder "name" indexes stable per host, and bookmark "name" indexes per folder
    $hostFolders = @{}  # server => folderNode
    $hostCounters = @{} # server => nextBookmarkIndex

    foreach ($element in $objects.unc) {

        if ([string]::IsNullOrWhiteSpace($element)) { continue }

        # Isolate Server: \\server\share\...
        $server = $null
        if ($element -match '^\\\\([^\\]+)\\') {
            $server = $Matches[1]
        } else {
            # If it's not a UNC, just bucket it under "(local/other)"
            $server = "(other)"
        }

        if (-not $hostFolders.ContainsKey($server)) {
            # Create folder bookmark (Type=0) under BookmarksToolbar
            $folder = $xmlfile.CreateElement("Bookmark")
            [void]$folder.SetAttribute("name", [string]$counterhosts)
            [void]$folder.SetAttribute("Type", "0")
            [void]$folder.SetAttribute("GUID", ([guid]::NewGuid().ToString()))
            [void]$folder.SetAttribute("ItemName", $server)
            [void]$folder.SetAttribute("DateCreatedLow", "3561811627")
            [void]$folder.SetAttribute("DateCreatedHigh", "3561811627")
            [void]$folder.SetAttribute("DateModifiedLow", "3561811627")
            [void]$folder.SetAttribute("DateModifiedHigh", "3561811627")

            [void]$toolbarNode.AppendChild($folder)

            $hostFolders[$server]  = $folder
            $hostCounters[$server] = 0
            $counterhosts++
        }

        # Add the actual bookmark (Type=1) inside the server folder
        $folderNode = $hostFolders[$server]
        $idx = [int]$hostCounters[$server]

        $bm = $xmlfile.CreateElement("Bookmark")
        [void]$bm.SetAttribute("name", [string]$idx)
        [void]$bm.SetAttribute("Type", "1")
        [void]$bm.SetAttribute("GUID", ([guid]::NewGuid().ToString()))
        [void]$bm.SetAttribute("ItemName", $element)
        [void]$bm.SetAttribute("Location", $element)
        [void]$bm.SetAttribute("DateCreatedLow", "3561811627")
        [void]$bm.SetAttribute("DateCreatedHigh", "3561811627")
        [void]$bm.SetAttribute("DateModifiedLow", "3561811627")
        [void]$bm.SetAttribute("DateModifiedHigh", "3561811627")

        [void]$folderNode.AppendChild($bm)

        $hostCounters[$server] = $idx + 1
        $counteruncstats++
    }

    # -----------------------------
    # Save
    # -----------------------------
    try {
        $xmlfile.Save($configPath)
        Write-Host "[+] Added $counterhosts bookmark-folders with $counteruncstats bookmarks"
        Write-Host "[+] Saved: $configPath"
    } catch {
        Write-Host "[-] Failed to save XML: $($_.Exception.Message)"
        exit
    }
}


# Function to export as CSV
function exportcsv($object ,$name){
	write-host "[*] Storing: $($outputname)_loot_$($name).csv"
	$object | select-object severity,rule,keyword,modified,extension,unc,content | Export-Csv -Path "$($outputname)_loot_$($name).csv" -NoTypeInformation
}

# Function to export as TXT
function exporttxt($object ,$name){
	write-host "[*] Storing: $($outputname)_loot_$($name).txt"
	$object | Format-Table severity,rule,keyword,modified,extension,unc,content -AutoSize | Out-String -Width 10000 | Out-File -FilePath "$($outputname)_loot_$($name).txt"
}

# Function to export as JSON
function exportjson($object ,$name){
	write-host "[*] Storing: $($outputname)_loot_$($name).json"
	$object | select-object severity,rule,keyword,modified,extension,unc,content | ConvertTo-Json -depth 50  | Out-File -FilePath "$($outputname)_loot_$($name).json"
}

# Function to export as HTML
function exporthtml($object ,$name){

# ---------------- JS: data-driven table with pagination ----------------
$Header = @'
<meta charset="utf-8">
<script>
  document.addEventListener("DOMContentLoaded", () => {
    // ----------------------------
    // Data bootstrap
    // ----------------------------
    const dataEl = document.getElementById("loot-data");
    if (!dataEl) {
      console.error("loot-data element not found");
      return;
    }
    const data = JSON.parse(dataEl.textContent);

    // ----------------------------
    // Report identity + storage keys
    // ----------------------------
    function getReportSha256() {
      const el = document.getElementById("report-sha256");
      const sha = (el ? el.textContent : "").trim();
      return sha || "";
    }

    function getCurrentFileName() {
      const path = window.location.pathname;
      return path.substring(path.lastIndexOf("/") + 1);
    }

    function getProgressKey() {
      const sha = getReportSha256();
      return sha
        ? `snaffler_progress::sha256::${sha}`
        : `snaffler_progress::file::${getCurrentFileName()}`;
    }

    // ----------------------------
    // Column visibility
    // ----------------------------
    const COLS = [
      { key: "check",     label: "\u2605 (flagged)" },
      { key: "done",      label: "\u2713 (done)" },
      { key: "invalid",   label: "\u274C (invalid)" },
      { key: "credScore", label: "\uD83D\uDD11 Conf (0-100)" },
      { key: "severity", label: "Severity" },
      { key: "rule", label: "Rule" },
      { key: "keyword", label: "Keyword" },
      { key: "modified", label: "Modified" },
      { key: "unc", label: "UNC" },
      { key: "extension", label: "Extensions" },
      { key: "actions", label: "Actions" },
      { key: "content", label: "Content" }
    ];

    function getColsKey() {
      const sha = getReportSha256();
      return sha ? `snaffler_cols::${sha}` : `snaffler_cols::${getCurrentFileName()}`;
    }

    let visibleCols = new Set(COLS.map(c => c.key)); // default: all

    function loadCols() {
      try {
        const raw = localStorage.getItem(getColsKey());
        if (!raw) return;
        const arr = JSON.parse(raw);
        if (Array.isArray(arr) && arr.length) visibleCols = new Set(arr);
      } catch {}
    }

    function saveCols() {
      try {
        localStorage.setItem(getColsKey(), JSON.stringify(Array.from(visibleCols)));
      } catch {}
    }

    function applyColsToTable() {
      const t = document.getElementById("loot-table");
      if (!t) return;

      // remove any previous hide-col-* classes
      t.className = t.className
        .split(/\s+/)
        .filter(c => c && !c.startsWith("hide-col-"))
        .join(" ");

      // add hide classes for columns NOT in visibleCols
      for (const c of COLS) {
        if (!visibleCols.has(c.key)) t.classList.add(`hide-col-${c.key}`);
      }
    }

    // ----------------------------
    // Progress persistence (check/done)
    // ----------------------------
    let progressSaveTimer = null;

    function loadProgressFromLocalStorage() {
      try {
        const raw = localStorage.getItem(getProgressKey());
        if (!raw) return;

        const saved = JSON.parse(raw);
        // saved.items is array of { i, c, d } where i = row index
        if (!saved || !Array.isArray(saved.items)) return;

        for (const it of saved.items) {
          const i = it.i;
          if (!Number.isInteger(i) || i < 0 || i >= data.length) continue;
          data[i].check   = !!it.c;
          data[i].done    = !!it.d;
          data[i].invalid = !!it.x;
        }
      } catch (e) {
        console.warn("Failed to load progress:", e);
      }
    }

    function saveProgressToLocalStorageDebounced() {
      clearTimeout(progressSaveTimer);
      progressSaveTimer = setTimeout(() => {
        try {
          // store only rows that have check or done = true (keeps storage small)
          const items = [];
          for (let i = 0; i < data.length; i++) {
            const r = data[i];
            if (r.check || r.done || r.invalid) items.push({ i, c: r.check ? 1 : 0, d: r.done ? 1 : 0, x: r.invalid ? 1 : 0 });
          }
          localStorage.setItem(getProgressKey(), JSON.stringify({ v: 1, items }));
        } catch (e) {
          console.warn("Failed to save progress:", e);
        }
      }, 150);
    }

    function resetProgressEverywhere() {
      // clear memory
      for (let i = 0; i < data.length; i++) {
        data[i].check   = false;
        data[i].done    = false;
        data[i].invalid = false;
      }

      // clear storage
      try { localStorage.removeItem(getProgressKey()); } catch {}

      // refresh UI
      page = 1;
      applyAll();
    }

    // ----------------------------
    // Small UI helpers
    // ----------------------------
    function flashCopied(btn) {
      if (!btn) return;

      const ico = btn.querySelector(".ico");
      if (!ico) return;

      if (!btn.dataset.orig) btn.dataset.orig = ico.textContent;

      ico.textContent = "\u2705";
      btn.classList.add("copied", "show-tip");

      clearTimeout(btn._copiedTimer);
      btn._copiedTimer = setTimeout(() => {
        ico.textContent = btn.dataset.orig;
        btn.classList.remove("copied", "show-tip");
      }, 800);
    }

    // ----------------------------
    // Toast notifications
    // ----------------------------
    function showToast(msg) {
      let toast = document.getElementById("snaffler-toast");
      if (!toast) {
        toast = document.createElement("div");
        toast.id = "snaffler-toast";
        document.body.appendChild(toast);
      }
      toast.textContent = msg;
      toast.classList.add("show");
      clearTimeout(toast._timer);
      toast._timer = setTimeout(() => toast.classList.remove("show"), 2800);
    }

    // faster compares than localeCompare on every call
    const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

    function toTime(s) {
      if (!s) return 0;
      const iso = String(s).replace(" ", "T");
      const t = Date.parse(iso);
      return Number.isFinite(t) ? t : 0;
    }

    // ----------------------------
    // State
    // ----------------------------
    const severityOrder = { Black: 0, Red: 1, Yellow: 2, Green: 3 };

    let sortCol = "credScore";
    let sortDir = "desc"; // default: highest confidence first
    let severityPrimary = false; // sort by credScore globally on load

    let page = 1;
    let pageSize = parseInt(document.getElementById("pageSize").value, 10);
    let searchQ = "";
    let searchTimer = null;
    let actionsWired = false;

    // Filters
    let selectedSeverities = new Set(["Black", "Red", "Yellow", "Green"]);
    let selectedYears = null; // Set, built from data
    let selectedExtensions = null; // Set, built from data
    let filterCheckOnly = false;
    let filterHideDone    = false;
    let filterHideInvalid  = false;
    let filterCredOnly     = false;
    let filterCredMinScore = 1;  // minimum credScore to show when filterCredOnly active

    const DEFAULT_SEVERITIES = ["Black", "Red", "Yellow", "Green"];
    let view = []; // indexes into data[]


    // ----------------------------
    // Readable content toggle
    // ----------------------------
    const READABLE_KEY = (() => {
      const sha = getReportSha256();
      return sha ? `snaffler_readable::${sha}` : `snaffler_readable::${getCurrentFileName()}`;
    })();

    let readableMode = false;


    // ----------------------------
    // Theme
    // ----------------------------
    const THEME_KEY = "snaffler_theme";

    function applyTheme(theme) {
      const t = (theme === "light") ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", t);
      localStorage.setItem(THEME_KEY, t);

      // update button label if it exists
      const btn = document.getElementById("theme-toggle");
      if (btn) btn.textContent = (t === "dark") ? "Light mode" : "Dark mode";
    }

    function initTheme() {
      const saved = localStorage.getItem(THEME_KEY);
      applyTheme(saved || "dark");
    }

    // ----------------------------
    // Data helpers
    // ----------------------------
    function getYear(modified) {
      const s = String(modified ?? "");
      const m = s.match(/(19|20)\d{2}/);
      return m ? m[0] : "(unknown)";
    }

    function normSeverity(s) {
      const x = String(s ?? "").trim().toLowerCase();
      if (x === "black") return "Black";
      if (x === "red") return "Red";
      if (x === "yellow") return "Yellow";
      if (x === "green") return "Green";
      return "";
    }

    function escapeHtml(s) {
      return String(s ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function applyReadableMode(on) {
      readableMode = !!on;
      document.documentElement.classList.toggle("readable-on", readableMode);

      const btn = document.getElementById("toggle-readable");
      if (btn) btn.textContent = readableMode ? "Unescape: ON" : "Unescape: OFF";

      try { localStorage.setItem(READABLE_KEY, readableMode ? "1" : "0"); } catch {}
    }

    function initReadableMode() {
      try {
        const raw = localStorage.getItem(READABLE_KEY);
        applyReadableMode(raw === "1");
      } catch {
        applyReadableMode(false);
      }
    }

    // Function to unescape snaffler preview text
    function makeReadablePreviewText(input) {
      let s = String(input ?? "");
      if (!s) return "";

      // 1) Normalize PowerShell line-continuation + escaped newline: `\r\n  -> \n
      s = s.replace(/`\r\n/g, "\n");

      // 2) Convert escaped newlines into real newlines
      s = s.replace(/\\r\\n/g, "\n");
      s = s.replace(/\\n/g, "\n");

      // 3) Convert escaped tabs to real tabs
      s = s.replace(/\\t/g, "\t");

      // 4) Convert escaped spaces "\ " to real spaces
      s = s.replace(/\\ /g, " ");

      // unescape common "backslash-escaped" punctuation: \$ \. \{ \} \( \) etc.
      s = s.replace(/\\([#$.{},()[\]|+*?^=!<>:;'"`-])/g, "$1");

      // unescape double-backslashes to single backslash (\\ -> \)
      s = s.replace(/\\\\/g, "\\");

      // 5) Merge multiple newlines into a single newline
      s = s.replace(/\n{2,}/g, "\n");

      return s;
    }

    
    function highlightKeyword(content, keyword) {
      const safe = escapeHtml(content);
      if (!keyword) return safe;
      // Escape all regex special chars so raw Snaffler rule patterns don't crash RegExp
      const k = String(keyword).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      let re;
      try { re = new RegExp("(" + k + ")", "gi"); } catch(e) { return safe; }
      return safe.replace(re, '<span class="hl-keyword">$1</span>');
    }

    // Sensitive terms highlighted in content column (case-insensitive).
    // Sensitive term patterns - stored as [cls, pattern_string] pairs.


    // Regex that matches FIELD=VALUE or FIELD: VALUE for real credential fields,
    // used to highlight the actual password VALUE in bright yellow.
    // Sensitive term patterns - stored as [cls, pattern_string] pairs.
    // Compiled fresh each highlightSensitiveTerms call to avoid stateful lastIndex on /g regexes.
    const SENSITIVE_PATTERNS = [
      // credentials / secrets -> red (field NAMES, not values)
      ["hl-cred", "passw(?:or)?d|passwd|passphrase|secret[-_.]?key|secret|api[-_.]?key|api[-_.]?token|apitoken|access[-_.]?key|access[-_.]?token|auth[-_.]?token|bearer[-_.]?token|client[-_.]?secret|private[-_.]?key|encryption[-_.]?key|session[-_.]?token|refresh[-_.]?token|\\btoken\\b|keystore|key[-_.]?pass(?:word)?|service[-_.]?account|credential|creds?"],
      // connection strings / database -> orange
      ["hl-conn", "connection[-_.]?str(?:ing)?|datasource|data[-_.]?source|\\bserver=|\\bdatabase=|initial[-_.]?catalog|jdbc:|odbc:|\\bdsn=|db[-_.]?pass(?:word)?|db[-_.]?user|db[-_.]?name|\\bmysql\\b|postgres(?:ql)?|\\bmssql\\b|sqlserver|\\bmongodb\\b|\\bredis\\b|elasticsearch|\\bhost=|\\bencrypt=|trustservercertificate"],
      // network / infrastructure -> yellow-amber
      ["hl-net", "smtp[-_.]|ftp[-_.]|ldaps?://|\\bproxy\\b|\\bvpn\\b|\\bfirewall\\b|\\bgateway\\b|\\bsubnet\\b|\\bvlan\\b|https?://[\\w\\-.]+"],
      // cloud / SaaS -> cyan
      ["hl-cloud", "amazonaws\\.com|azure\\.com|blob\\.core\\.windows\\.net|storage\\.googleapis\\.com|s3://|az://|subscription[-_.]?id|tenant[-_.]?id|client[-_.]?id|managed[-_.]?identity|\\barn:|account[-_.]?key|sas[-_.]?token|aws[-_.]?access|aws[-_.]?secret"],
      // hex hashes (MD5/SHA1/SHA256) -> purple
      ["hl-hash", "\\b(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{40}|[0-9a-fA-F]{32})\\b"],
      // long base64 blobs -> purple
      ["hl-hash", "[A-Za-z0-9+/]{48,}={0,2}"],
    ];

    const CRED_VALUE_RE = new RegExp(
      '(?:password|passwd|passw|strpassword|secret|' +
      'api[-_.]?key|apitoken|access[-_.]?(?:key|token)|' +
      'auth[-_.]?token|client[-_.]?secret|private[-_.]?key|' +
      'token|pwd|pword)' +
      '\\s*[=:]\\s*' +
      '["\x27]?([^\\s"\x27\x60\\r\\n<>,;{}()\\]\\\\]{4,})["\x27]?',
      'gi'
    );


    // JSON {"name":"Client_Secret","value":"realval"} pattern for highlight
    const JSON_CRED_VALUE_RE = new RegExp(
      '"name"\\s*:\\s*"[^"]*(?:secret|password|passwd|api[-_.]?key|token|client[-_.]?secret|access[-_.]?key|client[-_.]?id)[^"]*"' +
      '[\\s\\S]{0,300}?"value"\\s*:\\s*"([^"]{4,})"',
      'gi'
    );


    // XML appSettings key="password" value="realval" pattern for highlight
    const XML_KV_VALUE_RE = new RegExp(
      'key\\s*=\\s*["\x27](?:[^"\x27]*[-_.])?' +
      '(?:password|passwd|secret|api[-_.]?key|apikey|(?:access|auth|bearer|id|refresh|session|api)?[-_.]?token|client[-_.]?secret|access[-_.]?key)' +
      '(?:[-_.][^"\x27]*)?["\x27]\\s+value\\s*=\\s*["\x27]([^"\x27]{4,})["\x27]',
      'gi'
    );

    // Placeholders that should NOT be highlighted as real values
    const VALUE_PLACEHOLDER_RE = /^(\$|%\(|\{\{|true$|false$|null$|none$|undefined$|get-|read-|convert|password$|passwd$|secret$|changeme$|yourpassword$|example$|test$|demo$|dummy$|placeholder$|token$|admin$|login$|user$|username$)/i;

    function isHighlightableValue(val) {
      if (!val || val.length < 4) return false;
      if (VALUE_PLACEHOLDER_RE.test(val.trim())) return false;
      if (/^[a-z][a-zA-Z]{2,}$/.test(val.trim())) return false; // pure camelCase identifier
      if (/(your|my|enter|replace|sample|placeholder|todo|fixme|here)/i.test(val)) return false;
      // Must have some complexity
      let c = 0;
      if (/[A-Z]/.test(val)) c++; if (/[a-z]/.test(val)) c++;
      if (/\d/.test(val)) c++; if (/[^a-zA-Z0-9]/.test(val)) c++;
      if (val.length >= 8) c++;
      return c >= 3 || /^(ghp_|ghs_|AKIA|eyJ|glpat-|sk-[A-Za-z0-9]{10})/.test(val);
    }


    function highlightSensitiveTerms(htmlStr) {
      // Decode HTML entities so patterns match through &quot; encoded connection strings
      const decoded = htmlStr.replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
      // Pass 1: highlight real credential VALUES in bright yellow (hl-cred-found)
      let result = decoded.replace(/(<[^>]+>)|([^<]+)/g, (match, tag, text) => {
        if (tag) return tag;
        CRED_VALUE_RE.lastIndex = 0;
        return text.replace(CRED_VALUE_RE, (full, val) => {
          if (!isHighlightableValue(val)) return full;
          return full.replace(val, `<span class="hl-cred-found">${val}</span>`);
        });
      });
      // Pass 1b: JSON {"name":"Client_Secret","value":"realval"} pattern
      JSON_CRED_VALUE_RE.lastIndex = 0;
      result = result.replace(JSON_CRED_VALUE_RE, (full, val) => {
        if (!isHighlightableValue(val)) return full;
        return full.replace(val, `<span class="hl-cred-found">${val}</span>`);
      });
      // Pass 1c: XML appSettings key="password" value="realval" pattern
      XML_KV_VALUE_RE.lastIndex = 0;
      result = result.replace(XML_KV_VALUE_RE, (full, val) => {
        if (!isHighlightableValue(val)) return full;
        return full.replace(val, `<span class="hl-cred-found">${val}</span>`);
      });
      // Pass 2: field-name and other term highlights
      result = result.replace(/(<[^>]+>)|([^<]+)/g, (match, tag, text) => {
        if (tag) return tag;
        let out = text;
        for (const [cls, pat] of SENSITIVE_PATTERNS) {
          try {
            const re = new RegExp("(" + pat + ")", "gi");
            out = out.replace(re, `<span class="${cls}">$1</span>`);
          } catch(e) { /* skip bad pattern */ }
        }
        return out;
      });
      return result;
    }

    function highlightSearchEscaped(escapedText, query) {
      // escapedText MUST already be escaped via escapeHtml()
      const q = String(query || "").trim();
      if (!q) return escapedText;

      const tokens = q.toLowerCase().split(/\s+/).filter(t => t.length >= 1);
      if (!tokens.length) return escapedText;

      let out = escapedText;
      for (const tok of tokens) {
        const re = new RegExp(`(${tok.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi");
        out = out.replace(re, `<mark class="hit">$1</mark>`);
      }
      return out;
    }

    function parentOfUNC(unc) {
      if (!unc) return "";
      const p = unc.lastIndexOf("\\");
      return p > 1 ? unc.slice(0, p) : unc;
    }

    // ----------------------------
    // Actions column + clipboard helpers
    // ----------------------------
    function fallbackCopy(text) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch {}
      document.body.removeChild(ta);
    }

    function copyToClipboard(text) {
      const t = String(text || "");
      if (!t) return;

      // Modern clipboard API (works in secure contexts; file:// may vary)
      if (navigator.clipboard) {
        navigator.clipboard.writeText(t).catch(() => fallbackCopy(t));
      } else {
        fallbackCopy(t);
      }
    }

    function openLink(unc) {
      const parent = parentOfUNC(unc).replaceAll(" ", "%20");
      return `<a class="act act-open"
                target="_blank"
                href="file://${parent}/"
                title="Open folder"
                aria-label="Open folder">
                &#x1F4C2;
              </a>`;
    }

    function saveLink(unc) {
      const u = (unc || "").replaceAll(" ", "%20");
      return `<a class="act act-save"
                target="_blank"
                href="file://${u}"
                download
                title="Save file"
                aria-label="Save file">
                &#x1F4BE;
              </a>`;
    }

    function actionsHtml(unc) {
      const u = String(unc || "");
      const parent = parentOfUNC(u);

      const uAttr = escapeHtml(u);
      const pAttr = escapeHtml(parent);

      return `
        <div class="row-actions" data-unc="${uAttr}" data-parent="${pAttr}">
          <button class="act act-copy-unc" type="button" title="Copy UNC">
            <span class="ico">&#x1F4CB;</span><span class="tip">Copied</span>
          </button>
          <button class="act act-copy-parent" type="button" title="Copy parent UNC">
            <span class="ico">&#x1F4DD;</span><span class="tip">Copied</span>
          </button>
          ${openLink(u)}
          ${saveLink(u)}
        </div>
      `;
    }

    function colorSeverityVisible() {
      document.querySelectorAll("#loot-body tr td:nth-child(5)").forEach(td => {
        // ALWAYS reset first
        td.style.backgroundColor = "";
        td.style.color = "";

        const sev = td.textContent.trim();
        switch (sev) {
          case "Black":
            td.style.backgroundColor = "#333";
            td.style.color = "white";
            break;
          case "Red":
            td.style.backgroundColor = "#d9534f";
            td.style.color = "white";
            break;
          case "Yellow":
            td.style.backgroundColor = "#CFAD01";
            td.style.color = "white";
            break;
          case "Green":
            td.style.backgroundColor = "#79C55B";
            td.style.color = "white";
            break;
        }
      });
    }

    // ----------------------------
    // Save HTML (with embedded state)
    // ----------------------------
    function updateCheckboxAttributesForSave() {
      // Ensure current page checkboxes have checked attrs
      document.querySelectorAll("#loot-body input[type='checkbox']").forEach(cb => {
        if (cb.checked) cb.setAttribute("checked", "checked");
        else cb.removeAttribute("checked");
      });

      // IMPORTANT: write all checkbox states into JSON blob so saved HTML reloads state
      dataEl.textContent = JSON.stringify(data);
    }

    function saveStateToHTML() {
      updateCheckboxAttributesForSave();
      const html = document.documentElement.outerHTML;
      const blob = new Blob([html], { type: "text/html" });

      const currentFileName = getCurrentFileName();
      const newFileName = currentFileName.replace(/\.html$/, "") + "_save.html";

      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = newFileName;
      link.click();
    }

    // ----------------------------
    // Export current view to CSV
    // ----------------------------
    function csvEscape(v) {
      const s = String(v ?? "");
      // Always quote; escape quotes by doubling them
      return `"${s.replace(/"/g, '""')}"`;
    }

    function buildCsvFromRows(rows) {
      // Keep stable ordering, but only include visible columns
      const cols = COLS.filter(c => visibleCols.has(c.key));

      // Map column keys to row fields (actions is UI-only)
      const headers = cols
        .filter(c => c.key !== "actions")
        .map(c => c.key);

      let csv = headers.join(",") + "\r\n";

      for (const r of rows) {
        const line = headers.map(k => {
          if (k === "check")   return csvEscape(r.check   ? 1 : 0);
          if (k === "done")    return csvEscape(r.done    ? 1 : 0);
          if (k === "invalid")   return csvEscape(r.invalid   ? 1 : 0);
          if (k === "credScore") return csvEscape(r.credScore || 0);
          return csvEscape(r[k]);
        }).join(",");
        csv += line + "\r\n";
      }
      return csv;
    }

    function exportCurrentViewToCsv() {
      // view[] contains indexes into data[] for the current filtered/sorted dataset
      const rows = view.map(i => data[i]);

      const csv = buildCsvFromRows(rows);
      const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });

      const currentFileName = getCurrentFileName();
      const base = currentFileName.replace(/\.html$/i, "");
      const outName = `${base}_filtered_${rows.length}.csv`;

      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = outName;
      a.click();

      // (optional) cleanup
      setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    }

    // ----------------------------
    // Columns modal
    // ----------------------------
    function wireColumnsUi() {
      const btn = document.getElementById("cols-btn");
      const modal = document.getElementById("cols-modal");
      const close = document.getElementById("cols-close");
      const list = document.getElementById("cols-list");
      const allBtn = document.getElementById("cols-all");
      const noneBtn = document.getElementById("cols-none");
      const applyBtn = document.getElementById("cols-apply");

      if (!btn || !modal || !close || !list || !allBtn || !noneBtn || !applyBtn) return;

      function open() {
        // rebuild list each time so it reflects current state
        list.innerHTML = "";
        for (const c of COLS) {
          const label = document.createElement("label");
          label.className = "filter-inline";

          const cb = document.createElement("input");
          cb.type = "checkbox";
          cb.value = c.key;
          cb.checked = visibleCols.has(c.key);

          cb.addEventListener("change", () => {
            if (cb.checked) visibleCols.add(c.key);
            else visibleCols.delete(c.key);
          });

          label.appendChild(cb);
          label.appendChild(document.createTextNode(c.label));
          list.appendChild(label);
        }

        modal.classList.add("open");
        modal.setAttribute("aria-hidden", "false");
      }

      function closeModal() {
        modal.classList.remove("open");
        modal.setAttribute("aria-hidden", "true");
      }

      btn.addEventListener("click", open);
      close.addEventListener("click", closeModal);
      modal.addEventListener("click", (e) => { if (e.target === modal) closeModal(); });
      document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeModal(); });

      allBtn.addEventListener("click", () => {
        visibleCols = new Set(COLS.map(c => c.key));
        open(); // re-render
      });

      noneBtn.addEventListener("click", () => {
        visibleCols = new Set(); // allow empty; table will look blank
        open(); // re-render
      });

      applyBtn.addEventListener("click", () => {
        saveCols();
        applyColsToTable();
        closeModal();
      });
    }

    // ----------------------------
    // Header wiring (buttons + modals)
    // ----------------------------
    function wireHeader() {
      const saveBtn = document.getElementById("save-html");
      if (saveBtn) saveBtn.addEventListener("click", saveStateToHTML);

      const exportCsvBtn = document.getElementById("export-csv");
      if (exportCsvBtn) exportCsvBtn.addEventListener("click", exportCurrentViewToCsv);

      const themeBtn = document.getElementById("theme-toggle");
      if (themeBtn) {
        themeBtn.addEventListener("click", () => {
          const current = document.documentElement.getAttribute("data-theme") || "dark";
          applyTheme(current === "dark" ? "light" : "dark");
        });
      }

      // Reset progress (localStorage + current session)
      const resetProgressBtn = document.getElementById("reset-progress");
      if (resetProgressBtn) {
        resetProgressBtn.addEventListener("click", () => {
          if (!confirm("Reset stored progress (\u2605 flagged / \u2713 reviewed / \u274C invalid) for this report?")) return;
          resetProgressEverywhere();
        });
      }

      // Toggle Readability
      const readableBtn = document.getElementById("toggle-readable");
      if (readableBtn) {
        readableBtn.addEventListener("click", () => {
          applyReadableMode(!readableMode);
          // recompute on render: just re-render the current page
          renderPage();
          updatePager();
        });
      }


      // Bulk-mark invalid — floating panel
      const bulkInvalidBtn      = document.getElementById("bulk-invalid-btn");
      const bulkInvalidFloat    = document.getElementById("bulk-invalid-float");
      const bulkInvalidCollapse = document.getElementById("bulk-invalid-collapse");
      const bulkInvalidApply    = document.getElementById("bulk-invalid-apply");
      const bulkInvalidClear    = document.getElementById("bulk-invalid-clear");
      const bulkInvalidInput    = document.getElementById("bulk-invalid-input");
      const bulkInvalidScope    = document.getElementById("bulk-invalid-scope");
      const bulkInvalidCount    = document.getElementById("bulk-invalid-count");
      const bulkInvalidBody     = document.getElementById("bulk-invalid-float-body");

      // Persist collapsed state
      const BULK_COLLAPSED_KEY = "snaffler_bulk_collapsed";

      function setBulkCollapsed(on) {
        if (!bulkInvalidBody || !bulkInvalidCollapse) return;
        if (on) {
          bulkInvalidBody.style.display = "none";
          bulkInvalidCollapse.textContent = "+";
          bulkInvalidCollapse.title = "Expand panel";
        } else {
          bulkInvalidBody.style.display = "";
          bulkInvalidCollapse.textContent = "–";
          bulkInvalidCollapse.title = "Collapse panel";
        }
        try { localStorage.setItem(BULK_COLLAPSED_KEY, on ? "1" : "0"); } catch {}
      }

      function initBulkFloat() {
        if (!bulkInvalidFloat) return;
        // Hidden until toolbar button clicked the first time, or if previously shown
        const wasShown = localStorage.getItem("snaffler_bulk_shown") === "1";
        bulkInvalidFloat.style.display = wasShown ? "flex" : "none";
        const wasCollapsed = localStorage.getItem(BULK_COLLAPSED_KEY) === "1";
        setBulkCollapsed(wasCollapsed);
      }

      function showBulkFloat() {
        if (!bulkInvalidFloat) return;
        bulkInvalidFloat.style.display = "flex";
        setBulkCollapsed(false);
        try { localStorage.setItem("snaffler_bulk_shown", "1"); } catch {}
        setTimeout(() => bulkInvalidInput && bulkInvalidInput.focus(), 50);
      }

      function previewBulkInvalid() {
        const q = bulkInvalidInput.value.trim().toLowerCase();
        if (!q) { bulkInvalidCount.textContent = ""; return; }
        const scope = bulkInvalidScope.value;
        let hits = 0;
        for (let i = 0; i < data.length; i++) {
          if (matchesBulkQuery(data[i], q, scope)) hits++;
        }
        bulkInvalidCount.textContent = hits === 0 ? "No matches" : `${hits} row${hits === 1 ? "" : "s"} will be marked`;
        bulkInvalidCount.style.color = hits === 0 ? "#f66" : "#8f8";
      }

      function matchesBulkQuery(r, q, scope) {
        if (scope === "unc")     return (r.unc     || "").toLowerCase().includes(q);
        if (scope === "content") return (r.content || "").toLowerCase().includes(q);
        if (scope === "rule")    return (r.rule    || "").toLowerCase().includes(q);
        if (scope === "keyword") return (r.keyword || "").toLowerCase().includes(q);
        return ((r.unc || "") + " " + (r.rule || "") + " " + (r.keyword || "") + " " + (r.content || "")).toLowerCase().includes(q);
      }

      function applyBulkInvalid() {
        const q = bulkInvalidInput.value.trim().toLowerCase();
        if (!q) return;
        const scope = bulkInvalidScope.value;
        let count = 0;
        for (let i = 0; i < data.length; i++) {
          if (matchesBulkQuery(data[i], q, scope)) {
            data[i].invalid = true;
            count++;
          }
        }
        saveProgressToLocalStorageDebounced();
        applyAll();
        bulkInvalidInput.value = "";
        bulkInvalidCount.textContent = "";
        if (count > 0) showToast(`Marked ${count} row${count === 1 ? "" : "s"} as invalid.`);
      }

      function clearBulkInvalid() {
        if (!confirm("Clear ALL invalid (\u274C) marks from every row?")) return;
        for (let i = 0; i < data.length; i++) data[i].invalid = false;
        saveProgressToLocalStorageDebounced();
        applyAll();
        showToast("All invalid marks cleared.");
      }

      if (bulkInvalidBtn)      bulkInvalidBtn.addEventListener("click", showBulkFloat);
      if (bulkInvalidCollapse) bulkInvalidCollapse.addEventListener("click", () => {
        const isCollapsed = bulkInvalidBody.style.display === "none";
        setBulkCollapsed(!isCollapsed);
      });
      if (bulkInvalidApply)    bulkInvalidApply.addEventListener("click", applyBulkInvalid);
      if (bulkInvalidClear)    bulkInvalidClear.addEventListener("click", clearBulkInvalid);
      if (bulkInvalidInput)    bulkInvalidInput.addEventListener("input", previewBulkInvalid);
      if (bulkInvalidScope)    bulkInvalidScope.addEventListener("change", previewBulkInvalid);
      if (bulkInvalidInput)    bulkInvalidInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter")  { applyBulkInvalid(); e.preventDefault(); }
      });

      initBulkFloat();

      // Input Info modal
      const infoBtn = document.getElementById("show-input-info");
      const modal = document.getElementById("input-info-modal");
      const closeBtn = document.getElementById("modal-close");

      if (infoBtn && modal && closeBtn) {
        function openModal() {
          modal.classList.add("open");
          modal.setAttribute("aria-hidden", "false");
        }

        function closeModal() {
          modal.classList.remove("open");
          modal.setAttribute("aria-hidden", "true");
        }

        infoBtn.addEventListener("click", openModal);
        closeBtn.addEventListener("click", closeModal);

        modal.addEventListener("click", (e) => {
          if (e.target === modal) closeModal();
        });

        document.addEventListener("keydown", (e) => {
          if (e.key === "Escape") closeModal();
        });
      }
    }

    // ----------------------------
    // Filter UI (built from data)
    // ----------------------------
    function buildFilterMenu() {
      const filterMenu = document.getElementById("filter-menu");
      filterMenu.innerHTML = "";

      // Top bar: search + reset
      const topbar = document.createElement("div");
      topbar.className = "filter-topbar";

      const spacer = document.createElement("div");
      spacer.className = "spacer";

      const searchInput = document.createElement("input");
      searchInput.id = "q";
      searchInput.type = "text";
      searchInput.placeholder = "Search (unc / rule / keyword / content)...";

      const clearBtn = document.createElement("button");
      clearBtn.id = "clearSearch";
      clearBtn.textContent = "Clear";

      const resetBtn = document.createElement("button");
      resetBtn.id = "resetFilters";
      resetBtn.textContent = "Reset filters";

      topbar.appendChild(spacer);
      topbar.appendChild(searchInput);
      topbar.appendChild(clearBtn);
      topbar.appendChild(resetBtn);
      filterMenu.appendChild(topbar);

      // quick search wiring
      searchInput.addEventListener("input", () => {
        searchQ = searchInput.value.trim().toLowerCase();
        page = 1;
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => applyAll(), 350);
      });

      clearBtn.addEventListener("click", () => {
        searchInput.value = "";
        searchQ = "";
        page = 1;
        applyAll();
      });

      // Filter cards grid
      const grid = document.createElement("div");
      grid.className = "filter-grid";
      filterMenu.appendChild(grid);

      // Helper to create a collapsible card
      function makeCard(title, countText, openByDefault = true) {
        const d = document.createElement("details");
        d.className = "filter-card";
        if (openByDefault) d.open = true;

        const s = document.createElement("summary");
        s.textContent = title;

        const meta = document.createElement("span");
        meta.className = "meta";
        meta.textContent = countText || "";
        s.appendChild(meta);

        const body = document.createElement("div");
        body.style.marginTop = "8px";

        d.appendChild(s);
        d.appendChild(body);
        return { details: d, body, meta };
      }

      // Severity card
      const sevCard = makeCard("Severity", "", true);
      const sevList = document.createElement("div");
      sevList.className = "filter-list";

      ["Black", "Red", "Yellow", "Green"].forEach(sev => {
        const label = document.createElement("label");
        label.className = "filter-inline";

        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.value = sev;
        cb.checked = true;

        cb.addEventListener("change", () => {
          if (cb.checked) selectedSeverities.add(sev);
          else selectedSeverities.delete(sev);
          page = 1;
          applyAll();
          updateMetaCounts();
        });

        label.appendChild(cb);
        label.appendChild(document.createTextNode(sev));
        sevList.appendChild(label);
      });

      const sevActions = document.createElement("div");
      sevActions.className = "filter-actions-row";

      const sevAll = document.createElement("button");
      sevAll.textContent = "All";
      sevAll.addEventListener("click", () => {
        selectedSeverities = new Set(["Black", "Red", "Yellow", "Green"]);
        sevList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = true);
        page = 1;
        applyAll();
        updateMetaCounts();
      });

      const sevNone = document.createElement("button");
      sevNone.textContent = "None";
      sevNone.addEventListener("click", () => {
        selectedSeverities = new Set();
        sevList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = false);
        page = 1;
        applyAll();
        updateMetaCounts();
      });

      sevActions.appendChild(sevAll);
      sevActions.appendChild(sevNone);

      sevCard.body.appendChild(sevList);
      sevCard.body.appendChild(sevActions);
      grid.appendChild(sevCard.details);

      // Years card
      const yearSet = new Set();
      data.forEach(r => yearSet.add(getYear(r.modified)));

      const years = Array.from(yearSet).sort((a, b) => b.localeCompare(a));
      selectedYears = new Set(years);

      const yrCard = makeCard("Modified", years.length ? `${years.length} years` : "", true);
      const yrScroll = document.createElement("div");
      yrScroll.className = "filter-scroll";

      const yrList = document.createElement("div");
      yrList.className = "filter-list threecol";

      years.forEach(y => {
        const label = document.createElement("label");
        label.className = "filter-inline";

        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.className = "year-checkbox";
        cb.value = y;
        cb.checked = true;

        cb.addEventListener("change", () => {
          if (cb.checked) selectedYears.add(y);
          else selectedYears.delete(y);
          page = 1;
          applyAll();
          updateMetaCounts();
        });

        label.appendChild(cb);
        label.appendChild(document.createTextNode(y));
        yrList.appendChild(label);
      });

      yrScroll.appendChild(yrList);

      const yrActions = document.createElement("div");
      yrActions.className = "filter-actions-row";

      const yrAll = document.createElement("button");
      yrAll.textContent = "All";
      yrAll.addEventListener("click", () => {
        selectedYears = new Set(years);
        yrList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = true);
        page = 1;
        applyAll();
        updateMetaCounts();
      });

      const yrNone = document.createElement("button");
      yrNone.textContent = "None";
      yrNone.addEventListener("click", () => {
        selectedYears = new Set();
        yrList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = false);
        page = 1;
        applyAll();
        updateMetaCounts();
      });

      yrActions.appendChild(yrAll);
      yrActions.appendChild(yrNone);

      yrCard.body.appendChild(yrScroll);
      yrCard.body.appendChild(yrActions);
      grid.appendChild(yrCard.details);

      // Extensions card (scroll + mini-search)
      const extSet = new Set();
      data.forEach(r => {
        const e = (r.extension || "").toLowerCase().trim();
        extSet.add(e ? e : "(no ext)");
      });

      const exts = Array.from(extSet).sort((a, b) => a.localeCompare(b));
      selectedExtensions = new Set(exts);

      const extCard = makeCard("Extension", exts.length ? `${exts.length} types` : "", true);

      const extFilterInput = document.createElement("input");
      extFilterInput.className = "ext-search";
      extFilterInput.type = "text";
      extFilterInput.placeholder = "Filter extensions... (e.g. .ps1)";

      const extScroll = document.createElement("div");
      extScroll.className = "filter-scroll";

      const extList = document.createElement("div");
      extList.className = "filter-list threecol";

      function renderExtList(filterText = "") {
        extList.innerHTML = "";
        const ft = filterText.trim().toLowerCase();

        exts
          .filter(ext => !ft || ext.includes(ft))
          .forEach(ext => {
            const label = document.createElement("label");
            label.className = "filter-inline";

            const cb = document.createElement("input");
            cb.type = "checkbox";
            cb.className = "extension-checkbox";
            cb.value = ext;
            cb.checked = selectedExtensions.has(ext);

            cb.addEventListener("change", () => {
              if (cb.checked) selectedExtensions.add(ext);
              else selectedExtensions.delete(ext);
              page = 1;
              applyAll();
              updateMetaCounts();
            });

            label.appendChild(cb);
            label.appendChild(document.createTextNode(ext));
            extList.appendChild(label);
          });
      }

      renderExtList("");
      extFilterInput.addEventListener("input", () => renderExtList(extFilterInput.value));
      extScroll.appendChild(extList);

      const extActions = document.createElement("div");
      extActions.className = "filter-actions-row";

      const extAll = document.createElement("button");
      extAll.textContent = "All";
      extAll.addEventListener("click", () => {
        selectedExtensions = new Set(exts);
        renderExtList(extFilterInput.value);
        page = 1;
        applyAll();
        updateMetaCounts();
      });

      const extNone = document.createElement("button");
      extNone.textContent = "None";
      extNone.addEventListener("click", () => {
        selectedExtensions = new Set();
        renderExtList(extFilterInput.value);
        page = 1;
        applyAll();
        updateMetaCounts();
      });

      extActions.appendChild(extAll);
      extActions.appendChild(extNone);

      extCard.body.appendChild(extFilterInput);
      extCard.body.appendChild(extScroll);
      extCard.body.appendChild(extActions);
      grid.appendChild(extCard.details);

      // Status card (check/done filters)
      const statusCard = makeCard("Status", "", true);

      const statusList = document.createElement("div");
      statusList.className = "filter-list onecol";

      const checkOnlyLabel = document.createElement("label");
      checkOnlyLabel.className = "filter-inline";

      const checkOnlyCb = document.createElement("input");
      checkOnlyCb.type = "checkbox";
      checkOnlyCb.checked = filterCheckOnly;

      checkOnlyCb.addEventListener("change", () => {
        filterCheckOnly = checkOnlyCb.checked;
        page = 1;
        applyAll();
      });

      checkOnlyLabel.appendChild(checkOnlyCb);
      checkOnlyLabel.appendChild(document.createTextNode("Show \u2605 (flagged) only"));

      const hideDoneLabel = document.createElement("label");
      hideDoneLabel.className = "filter-inline";

      const hideDoneCb = document.createElement("input");
      hideDoneCb.type = "checkbox";
      hideDoneCb.checked = filterHideDone;

      hideDoneCb.addEventListener("change", () => {
        filterHideDone = hideDoneCb.checked;
        page = 1;
        applyAll();
      });

      hideDoneLabel.appendChild(hideDoneCb);
      hideDoneLabel.appendChild(document.createTextNode("Hide \u2713 (done)"));

      const hideInvalidLabel = document.createElement("label");
      hideInvalidLabel.className = "filter-inline";

      const hideInvalidCb = document.createElement("input");
      hideInvalidCb.type = "checkbox";
      hideInvalidCb.checked = false;

      hideInvalidCb.addEventListener("change", () => {
        filterHideInvalid = hideInvalidCb.checked;
        page = 1;
        applyAll();
      });

      hideInvalidLabel.appendChild(hideInvalidCb);
      hideInvalidLabel.appendChild(document.createTextNode("Hide \u274C (invalid)"));

      const credOnlyLabel = document.createElement("label");
      credOnlyLabel.className = "filter-inline";

      const credOnlyCb = document.createElement("input");
      credOnlyCb.type = "checkbox";
      credOnlyCb.checked = false;

      credOnlyCb.addEventListener("change", () => {
        filterCredOnly = credOnlyCb.checked;
        page = 1;
        applyAll();
      });

      credOnlyLabel.appendChild(credOnlyCb);
      credOnlyLabel.appendChild(document.createTextNode("\uD83D\uDD11 Creds: min score "));

      const credScoreSel = document.createElement("select");
      credScoreSel.style.cssText = "padding:2px 4px;border-radius:5px;border:1px solid #555;background:rgba(30,30,30,0.9);color:inherit;font-size:11px;cursor:pointer;margin-left:2px;";
      [["1","\uD83D\uDD11 Any (1+)"],["15","15+ (enc/connstr)"],["40","40+ (medium)"],["75","75+ (likely cred)"],["88","88+ (high conf)"]].forEach(([v,l]) => {
        const o = document.createElement("option"); o.value = v; o.textContent = l;
        credScoreSel.appendChild(o);
      });
      credScoreSel.addEventListener("change", () => {
        filterCredMinScore = parseInt(credScoreSel.value, 10);
        page = 1;
        applyAll();
      });
      credOnlyLabel.appendChild(credScoreSel);

      statusList.appendChild(checkOnlyLabel);
      statusList.appendChild(hideDoneLabel);
      statusList.appendChild(hideInvalidLabel);
      statusList.appendChild(credOnlyLabel);

      statusCard.body.appendChild(statusList);
      grid.appendChild(statusCard.details);

      // Row count display
      const rowCountDisplay = document.createElement("div");
      rowCountDisplay.id = "row-count";
      rowCountDisplay.style.marginTop = "10px";
      rowCountDisplay.className = "filter-mini";
      filterMenu.appendChild(rowCountDisplay);

      // Meta counts (optional)
      function updateMetaCounts() {
        sevCard.meta.textContent = `${selectedSeverities.size}/4`;
        yrCard.meta.textContent = years.length ? `${selectedYears.size}/${years.length}` : "";
        extCard.meta.textContent = exts.length ? `${selectedExtensions.size}/${exts.length}` : "";
      }
      updateMetaCounts();

      // Reset filters button needs access to these built elements/arrays
      resetBtn.addEventListener("click", () => {
        searchInput.value = "";
        searchQ = "";

        selectedSeverities = new Set(DEFAULT_SEVERITIES);
        selectedYears = new Set(years);
        selectedExtensions = new Set(exts);
        filterCheckOnly   = false;
        filterHideDone    = false;
        filterHideInvalid = false;
        filterCredOnly    = false;

        sevList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = true);
        yrList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = true);

        extFilterInput.value = "";
        renderExtList("");
        extList.querySelectorAll("input[type=checkbox]").forEach(cb => cb.checked = true);

        checkOnlyCb.checked  = false;
        hideDoneCb.checked   = false;
        if (typeof credOnlyCb !== "undefined") credOnlyCb.checked = false;
        filterCredMinScore = 1;
        if (typeof credScoreSel !== "undefined") credScoreSel.value = "1";

        page = 1;
        applyAll();
        updateMetaCounts();
      });
    }

    // ----------------------------
    // Filtering + sorting (build view[])
    // ----------------------------
    function applyAll() {
      view = [];

      for (let i = 0; i < data.length; i++) {
        const r = data[i];

        if (!selectedSeverities.has(r.severity)) continue;

        if (selectedYears) {
          const y = getYear(r.modified);
          if (!selectedYears.has(y)) continue;
        }

        if (selectedExtensions) {
          const e = (r.extension || "").toLowerCase().trim();
          const key = e ? e : "(no ext)";
          if (!selectedExtensions.has(key)) continue;
        }

        if (filterCheckOnly && !r.check) continue;
        if (filterHideDone    && r.done)    continue;
        if (filterHideInvalid && r.invalid)   continue;
        if (filterCredOnly   && (r.credScore || 0) < filterCredMinScore) continue;

        if (searchQ) {
          const hay = `${r.unc||""} ${r.rule||""} ${r.keyword||""} ${r.content||""} ${r.severity||""} ${r.modified||""} ${r.extension||""}`.toLowerCase();
          if (!hay.includes(searchQ)) continue;
        }

        view.push(i);
      }

      view.sort((ia, ib) => {
        const a = data[ia], b = data[ib];

        const sa = severityOrder[normSeverity(a.severity)] ?? 999;
        const sb = severityOrder[normSeverity(b.severity)] ?? 999;

        if (severityPrimary) {
          if (sa !== sb) return sa - sb;

          if (sortCol === "modified") {
            const ta = toTime(a.modified), tb = toTime(b.modified);
            return (sortDir === "asc") ? (ta - tb) : (tb - ta);
          }

          if (sortCol === "check" || sortCol === "done" || sortCol === "invalid") {
            const va = !!a[sortCol], vb = !!b[sortCol];
            if (va === vb) return 0;
            return (sortDir === "asc") ? (va ? -1 : 1) : (va ? 1 : -1);
          }
          if (sortCol === "credScore") {
            const va = a.credScore || 0, vb = b.credScore || 0;
            if (va === vb) return 0;
            return (sortDir === "asc") ? va - vb : vb - va;
          }

          const va = (a[sortCol] ?? "").toString();
          const vb = (b[sortCol] ?? "").toString();
          const cmp = collator.compare(va, vb);
          return (sortDir === "asc") ? cmp : -cmp;
        }

        // global sort mode
        if (sortCol === "check" || sortCol === "done" || sortCol === "invalid") {
          const va = !!a[sortCol], vb = !!b[sortCol];
          if (va !== vb) return (sortDir === "asc") ? (va ? -1 : 1) : (va ? 1 : -1);
        } else if (sortCol === "credScore") {
          const va = a.credScore || 0, vb = b.credScore || 0;
          if (va !== vb) return (sortDir === "asc") ? va - vb : vb - va;
        } else if (sortCol === "modified") {
          const ta = toTime(a.modified), tb = toTime(b.modified);
          if (ta !== tb) return (sortDir === "asc") ? (ta - tb) : (tb - ta);
        } else if (sortCol === "severity") {
          if (sa !== sb) return (sortDir === "asc") ? (sa - sb) : (sb - sa);
        } else {
          const va = (a[sortCol] ?? "").toString();
          const vb = (b[sortCol] ?? "").toString();
          const cmp = collator.compare(va, vb);
          if (cmp !== 0) return (sortDir === "asc") ? cmp : -cmp;
        }

        if (sa !== sb) return sa - sb;
        return toTime(b.modified) - toTime(a.modified);
      });

      const totalPages = Math.max(1, Math.ceil(view.length / pageSize));
      page = Math.min(Math.max(page, 1), totalPages);

      renderPage();
      updatePager();
      updateRowCount();
    }

    // ----------------------------
    // Render current page
    // ----------------------------
    function renderPage() {
      const tbody = document.getElementById("loot-body");
      tbody.innerHTML = "";

      const start = (page - 1) * pageSize;
      const end = Math.min(view.length, start + pageSize);

      const frag = document.createDocumentFragment();

      for (let k = start; k < end; k++) {
        const idx = view[k];
        const r = data[idx];

        const sevHtml = escapeHtml(r.severity);
        const ruleHtml = highlightSearchEscaped(escapeHtml(r.rule), searchQ);
        const keywordHtml = highlightSearchEscaped(escapeHtml(r.keyword), searchQ);
        const modHtml = escapeHtml(r.modified);
        const uncHtml = highlightSearchEscaped(escapeHtml(r.unc), searchQ);
        const extHtml = highlightSearchEscaped(escapeHtml(r.extension), searchQ);

        // content: keyword highlight -> sensitive terms -> search highlight
        const rawContent = readableMode ? makeReadablePreviewText(r.content) : String(r.content ?? "");
        const contentKeyHtml = highlightKeyword(rawContent, r.keyword);
        const contentSensHtml = highlightSensitiveTerms(contentKeyHtml);
        const contentHtml = highlightSearchEscaped(contentSensHtml, searchQ);

        const tr = document.createElement("tr");

        // apply row classes based on saved state
        if (r.check)     tr.classList.add("flagged");
        if (r.done)      tr.classList.add("done");
        if (r.invalid)   tr.classList.add("invalid");
        const cs = r.credScore || 0;
        if      (cs >= 75) tr.classList.add("cred-crit");
        else if (cs >= 40) tr.classList.add("cred-high");
        else if (cs >= 15) tr.classList.add("cred-mid");
        else if (cs >= 1)  tr.classList.add("cred-low");

        tr.innerHTML = `
          <td><input type="checkbox" class="chk-check"    title="Flag"     data-idx="${idx}" ${r.check   ? "checked" : ""}></td>
          <td><input type="checkbox" class="chk-done"     title="Reviewed" data-idx="${idx}" ${r.done    ? "checked" : ""}></td>
          <td><input type="checkbox" class="chk-invalid"  title="Invalid"  data-idx="${idx}" ${r.invalid ? "checked" : ""}></td>
          <td class="cred-score-cell ${(()=>{const s=r.credScore||0;return s>=75?'cred-score-cr':s>=40?'cred-score-hi':s>=15?'cred-score-md':s>=1?'cred-score-lo':'cred-score-0'})()} " title="Confidence score: ${r.credScore||0}/100">${r.credScore||0}</td>
          <td>${sevHtml}</td>
          <td>${ruleHtml}</td>
          <td>${keywordHtml}</td>
          <td>${modHtml}</td>
          <td>${uncHtml}</td>
          <td>${extHtml}</td>
          <td>${actionsHtml(r.unc)}</td>
          <td>${contentHtml}</td>
        `;

        frag.appendChild(tr);
      }

      tbody.appendChild(frag);

      // checkbox wiring (only visible page)
      tbody.querySelectorAll(".chk-check").forEach(cb => {
        cb.addEventListener("change", (e) => {
          const i = parseInt(e.target.dataset.idx, 10);
          data[i].check = e.target.checked;

          const tr = e.target.closest("tr");
          if (tr) tr.classList.toggle("flagged", e.target.checked);

          saveProgressToLocalStorageDebounced();
          if (filterCheckOnly) applyAll();
        });
      });

      tbody.querySelectorAll(".chk-done").forEach(cb => {
        cb.addEventListener("change", (e) => {
          const i = parseInt(e.target.dataset.idx, 10);
          data[i].done = e.target.checked;

          const tr = e.target.closest("tr");
          if (tr) tr.classList.toggle("done", e.target.checked);

          saveProgressToLocalStorageDebounced();
          if (filterHideDone) applyAll();
        });
      });

      tbody.querySelectorAll(".chk-invalid").forEach(cb => {
        cb.addEventListener("change", (e) => {
          const i = parseInt(e.target.dataset.idx, 10);
          data[i].invalid = e.target.checked;

          const tr = e.target.closest("tr");
          if (tr) tr.classList.toggle("invalid", e.target.checked);

          saveProgressToLocalStorageDebounced();
          if (filterHideInvalid) applyAll();
        });
      });

      colorSeverityVisible();
    }

    function updatePager() {
      const totalPages = Math.max(1, Math.ceil(view.length / pageSize));
      document.getElementById("pageInfo").textContent =
        `Page ${page}/${totalPages} - ${view.length} rows (filtered)`;

      document.getElementById("prevPage").disabled = (page <= 1);
      document.getElementById("nextPage").disabled = (page >= totalPages);

      syncPageJumpUi();
    }

    function updateRowCount() {
      const el = document.getElementById("row-count");
      if (el) el.textContent = `Visible files: ${view.length} of ${data.length}`;
    }


    function getTotalPages() {
      return Math.max(1, Math.ceil(view.length / pageSize));
    }

    function syncPageJumpUi() {
      const input = document.getElementById("pageJump");
      if (!input) return;

      const total = getTotalPages();
      input.max = String(total);

      // Keep input value in sync without being annoying.
      // Only overwrite if empty or invalid.
      const n = parseInt(input.value, 10);
      if (!Number.isInteger(n) || n < 1 || n > total) {
        input.value = String(page);
      }
    }

    function gotoPage(n) {
      const total = getTotalPages();
      const next = Math.min(Math.max(parseInt(n, 10) || 1, 1), total);
      if (next === page) {
        syncPageJumpUi();
        return;
      }

      page = next;
      renderPage();
      updatePager();
      syncPageJumpUi();
    }

    function wirePageJump() {
      const input = document.getElementById("pageJump");
      const btn = document.getElementById("pageJumpGo");
      if (!input || !btn) return;

      btn.addEventListener("click", () => gotoPage(input.value));

      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          gotoPage(input.value);
          e.preventDefault();
        }
      });

      input.addEventListener("blur", () => {
        // Clamp on blur so the user can type freely.
        gotoPage(input.value);
      });

      syncPageJumpUi();
    }


    // ----------------------------
    // Sorting + paging controls
    // ----------------------------
    document.querySelectorAll("#loot-table thead th").forEach(th => {
      th.style.cursor = "pointer";
      th.addEventListener("click", () => {
        const col = th.getAttribute("data-col");
        if (!col) return;
        if (col === "actions") return;

        const mapped = (col === "content") ? "content" : col;

        if (sortCol === mapped) {
          sortDir = (sortDir === "asc") ? "desc" : "asc";
        } else {
          sortCol = mapped;
          sortDir = (sortCol === "modified" || sortCol === "credScore") ? "desc" : "asc";
        }

        severityPrimary = false;
        page = 1;
        applyAll();
      });
    });

    document.getElementById("prevPage").addEventListener("click", () => {
      gotoPage(page - 1);
    });

    document.getElementById("nextPage").addEventListener("click", () => {
      gotoPage(page + 1);
    });

    document.getElementById("pageSize").addEventListener("change", (e) => {
      pageSize = parseInt(e.target.value, 10);
      page = 1;
      applyAll();
    });

    // ----------------------------
    // Keyboard nav (checkbox columns)
    // ----------------------------
    document.addEventListener("keydown", (event) => {
      const active = document.activeElement;
      if (!active || active.type !== "checkbox") return;

      const td = active.closest("td");
      const tr = active.closest("tr");
      if (!td || !tr) return;

      const colIndex = td.cellIndex;
      let targetRow = null;

      if (event.key === "ArrowUp" || event.key.toLowerCase() === "w") targetRow = tr.previousElementSibling;
      if (event.key === "ArrowDown" || event.key.toLowerCase() === "s") targetRow = tr.nextElementSibling;

      if (targetRow) {
        const targetCb = targetRow.cells[colIndex]?.querySelector("input[type='checkbox']");
        if (targetCb) targetCb.focus();
        event.preventDefault();
        return;
      }

      if (event.key === "ArrowLeft" || event.key.toLowerCase() === "a") {
        const checkCb = tr.cells[0]?.querySelector("input[type='checkbox']");
        if (checkCb) checkCb.focus();
        event.preventDefault();
        return;
      }

      if (event.key === "ArrowRight" || event.key.toLowerCase() === "d") {
        const doneCb = tr.cells[1]?.querySelector("input[type='checkbox']");
        if (doneCb) doneCb.focus();
        event.preventDefault();
        return;
      }

      if (event.key === " ") {
        active.checked = !active.checked;
        active.dispatchEvent(new Event("change"));
        event.preventDefault();
      }

      // 1 = toggle ★ (flag), 2 = toggle ✓ (done)
      if (event.key === "1" || event.key === "2" || event.key === "3") {
        const tr = active.closest("tr");
        if (!tr) return;

        const targetCol = (event.key === "1") ? 0 : (event.key === "2") ? 1 : 2; // 0=check, 1=done, 2=invalid (credScore col 3 is read-only)
        const targetCb = tr.cells[targetCol]?.querySelector("input[type='checkbox']");
        if (!targetCb) return;

        targetCb.checked = !targetCb.checked;
        targetCb.dispatchEvent(new Event("change", { bubbles: true }));
        targetCb.focus();

        event.preventDefault();
        return;
      }
    });

    // ----------------------------
    // One-time wiring (event delegation for actions)
    // ----------------------------
    if (!actionsWired) {
      actionsWired = true;
      const tbody = document.getElementById("loot-body");

      tbody.addEventListener("click", (e) => {
        const btn = e.target.closest(".act");
        if (!btn) return;
        if (btn.tagName.toLowerCase() === "a") return;

        const wrap = btn.closest(".row-actions");
        if (!wrap) return;

        const unc = wrap.getAttribute("data-unc") || "";
        const parent = wrap.getAttribute("data-parent") || "";

        if (btn.classList.contains("act-copy-unc")) {
          copyToClipboard(unc);
          flashCopied(btn);
        }
        if (btn.classList.contains("act-copy-parent")) {
          copyToClipboard(parent);
          flashCopied(btn);
        }
      });
    }

    // ----------------------------
    // Init
    // ----------------------------
    initTheme();
    initReadableMode();
    wireHeader();
    // Normalise credScore to number (guards against string serialisation edge cases)
    for (let i = 0; i < data.length; i++) {
      data[i].credScore = parseInt(data[i].credScore, 10) || 0;
    }
    loadProgressFromLocalStorage();
    loadCols();
    applyColsToTable();
    wireColumnsUi();
    buildFilterMenu();
    wirePageJump();
    applyAll();
  });
</script>

'@

# ---------------- CSS ----------------

$css = @"
<style>
  /* Theme hint for native controls */
  :root { 
    color-scheme: dark;
    --report-header-offset: 64px; /* adjust once to match real header height */
  }
  html[data-theme="dark"] { color-scheme: dark; }
  html[data-theme="light"] { color-scheme: light; }

  /* =========================
     Base / Typography
     ========================= */
  body {
    background-color: #121212;
    color: #E0E0E0;
    font-family: Arial, Helvetica, sans-serif;
    font-size: 14px;
    margin: 0;
    padding: 0;
  }

  h1,
  h2 {
    color: #BB86FC;
  }

  /* =========================
     Buttons / Inputs
     ========================= */
  button {
    background-color: rgb(106, 145, 230);
    border: none;
    color: #fff;
    padding: 10px 10px;
    text-align: center;
    display: inline-block;
    font-size: 12px;
    margin: 5px 2px;
    cursor: pointer;
    border-radius: 5px;
    transition: background-color 0.3s, transform 0.2s;
  }

  button:hover {
    background-color: rgb(74, 124, 231);
    transform: scale(1.05);
  }

  button:active {
    background-color: rgb(52, 110, 235);
    transform: scale(0.98);
  }

  input[type="checkbox"] {
    width: 14px;
    height: 14px;
    margin: 4px;
    background-color: #fff;
    border: 2px solid #ccc;
    border-radius: 3px;
    cursor: pointer;
  }

  /* Generic icon helper (used outside of row-actions too) */
  .icon {
    font-size: 20px;
    line-height: 1;
    display: inline-block;
    width: 24px;
    height: 24px;
    text-align: center;
  }

  .icon:hover {
    transform: scale(1.2);
    transition: transform 0.2s ease, color 0.2s ease;
  }

  /* =========================
     Sticky report header
     ========================= */
  #report-header {
    position: sticky;
    top: 0;
    z-index: 3000;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 12px 14px;
    border-bottom: 1px solid #333;
    background: rgba(18, 18, 18, 0.92);
    backdrop-filter: blur(6px);
  }

  .hdr-left {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 280px;
  }

  .hdr-title {
    display: flex;
    align-items: baseline;
    gap: 10px;
    font-size: 18px;
    font-weight: 800;
    color: inherit;
  }

  .hdr-name {
    font-size: 18px;
    font-weight: 900;
  }

  .hdr-sub {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    opacity: 0.9;
  }

  .hdr-meta { white-space: nowrap; }
  .hdr-dot { opacity: 0.5; }

  .hdr-right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    justify-content: flex-end;
  }

  .hdr-link {
    font-size: 12px;
    color: inherit;
    opacity: 0.85;
    text-decoration: none;
    padding: 8px 10px;
    border: 1px solid #444;
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.03);
  }

  .hdr-link:hover {
    opacity: 1;
    text-decoration: underline;
  }

  /* Severity mini-colors in header */
  .hdr-sub .sev.black { color: #fff; }
  .hdr-sub .sev.red { color: #ff6b6b; }
  .hdr-sub .sev.yellow { color: #f1c40f; }
  .hdr-sub .sev.green { color: #2ecc71; }

  /* When report header is sticky, keep table header below it */
  th {
    top: var(--report-header-offset);
    z-index: 2000; /* keep above rows but below report header */
  }

  /* =========================
     Filter UI
     ========================= */
  #filter-menu {
    margin: 10px 0 14px 0;
    padding: 12px;
    border: 1px solid #333;
    border-radius: 10px;
    background: rgba(255, 255, 255, 0.02);
  }

  .filter-topbar {
    display: flex;
    gap: 10px;
    align-items: center;
    flex-wrap: wrap;
    margin-bottom: 10px;
  }

  .filter-topbar .spacer { flex: 1; }

  .filter-topbar input[type="text"] {
    min-width: 280px;
    padding: 7px 10px;
    border-radius: 8px;
    border: 1px solid #444;
    background: rgba(255, 255, 255, 0.03);
    color: inherit;
    outline: none;
  }

  .filter-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(220px, 1fr));
    gap: 10px;
  }

  @media (max-width: 1100px) {
    .filter-grid {
      grid-template-columns: repeat(2, minmax(220px, 1fr));
    }
  }

  @media (max-width: 780px) {
    .filter-grid { grid-template-columns: 1fr; }

    .filter-topbar input[type="text"] {
      min-width: 200px;
      width: 100%;
    }
  }

  details.filter-card {
    border: 1px solid #333;
    border-radius: 10px;
    padding: 8px 10px;
    background: rgba(255, 255, 255, 0.02);
  }

  details.filter-card > summary {
    cursor: pointer;
    font-weight: 700;
    user-select: none;
    list-style: none;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  details.filter-card > summary::-webkit-details-marker {
    display: none;
  }

  .filter-card .meta {
    font-weight: 400;
    opacity: 0.8;
    margin-left: auto;
    font-size: 12px;
  }

  .filter-list {
    margin-top: 8px;
    display: grid;
    grid-template-columns: repeat(2, minmax(140px, 1fr));
    gap: 6px 10px;
  }

  .filter-list.threecol {
    grid-template-columns: repeat(3, minmax(120px, 1fr));
  }

  .filter-list.onecol {
    grid-template-columns: 1fr;
  }

  .filter-scroll {
    max-height: 180px;
    overflow: auto;
    padding-right: 6px;
  }

  .filter-actions-row {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    margin-top: 8px;
  }

  .filter-mini {
    font-size: 12px;
    opacity: 0.85;
  }

  .filter-inline {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin-right: 12px;
  }

  .ext-search {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    margin-top: 6px;
    padding: 6px 8px;
    border-radius: 8px;
    border: 1px solid #444;
    background: rgba(255, 255, 255, 0.03);
    color: inherit;
  }

  /* =========================
     Table layout
     ========================= */
  #loot-table {
    width: 100%;
    max-width: 100%;
    margin-top: 5px;
    table-layout: fixed;
    border-collapse: collapse;
    font-size: 14px;
  }

  /* Column widths (needs your <colgroup> classes) */
  #loot-table col.c-check   { width: 32px; }
  #loot-table col.c-done    { width: 32px; }
  #loot-table col.c-invalid { width: 32px; }
  #loot-table col.c-cred    { width: 38px; }
  #loot-table col.c-sev { width: 70px; }
  #loot-table col.c-actions { width: 140px; }
  #loot-table col.c-mod { width: 160px; }
  #loot-table col.c-ext { width: 90px; }
  #loot-table col.c-rule { width: 185px; }
  #loot-table col.c-key { width: 160px; }

  /* Let UNC + content take the remaining space */
  #loot-table col.c-unc { width: 360px; }
  /* c-content: no width => gets the rest */

  /* Default: no wrapping + ellipsis for compact columns */
  #loot-table td,
  #loot-table th {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  #loot-table td {
    vertical-align: middle;
  }

  th {
    background: #282a36;
    color: #E0E0E0;
    font-size: 14px;
    font-weight: bold;
    padding: 8px;
    text-align: left;
    border: 1px solid #333;
    border-bottom: 2px solid #838383;
    position: sticky;
    cursor: pointer;
  }

  td {
    padding: 6px;
    border: 1px solid #333;
  }

  /* Center severity + actions columns */
  table td:nth-child(5),
  table td:nth-child(11) {
    text-align: center;
    vertical-align: middle;
  }

  tbody tr:nth-child(even) { background-color: #1A1A1A; }
  tbody tr:nth-child(odd) { background-color: #2A2A2A; }

  tbody tr:hover td:not(:nth-child(5)) {
    background-color: #444 !important;
  }

  /* Compact icon headers */
  #loot-table th[data-col="check"],
  #loot-table th[data-col="done"],
  #loot-table th[data-col="invalid"],
  #loot-table th[data-col="credScore"] {
    text-align: center;
    font-size: 16px;
    font-weight: 700;
    width: 32px;
  }

  /* Center first two checkbox columns */
  #loot-table td:nth-child(1),
  #loot-table td:nth-child(2),
  #loot-table td:nth-child(3),
  #loot-table td:nth-child(4) {
    text-align: center;
    vertical-align: middle;
    padding: 0;
  }

  #loot-table td:nth-child(1) input[type="checkbox"],
  #loot-table td:nth-child(2) input[type="checkbox"],
  #loot-table td:nth-child(3) input[type="checkbox"] {
    display: block;
    margin: 0 auto;
  }

  /* Allow wrapping only in UNC + content */
  #loot-table td:nth-child(9),   /* UNC */
  #loot-table td:nth-child(12) { /* content */
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    overflow-wrap: anywhere;
    word-break: break-word;
  }

  /* Actions column: allow tooltip to escape the cell */
  #loot-table td:nth-child(11),
  #loot-table th:nth-child(11) {
    overflow: visible !important;
  }

  #loot-table td:nth-child(11) {
    position: relative;
    z-index: 5;
  }

  /* =========================
     Column visibility toggles
     ========================= */
  #loot-table.hide-col-check th:nth-child(1),
  #loot-table.hide-col-check td:nth-child(1),
  #loot-table.hide-col-check col.c-check { display: none !important; }

  #loot-table.hide-col-done th:nth-child(2),
  #loot-table.hide-col-done td:nth-child(2),
  #loot-table.hide-col-done col.c-done { display: none !important; }

  #loot-table.hide-col-invalid th:nth-child(3),
  #loot-table.hide-col-invalid td:nth-child(3),
  #loot-table.hide-col-invalid col.c-invalid { display: none !important; }

  #loot-table.hide-col-credScore th:nth-child(4),
  #loot-table.hide-col-credScore td:nth-child(4),
  #loot-table.hide-col-credScore col.c-cred { display: none !important; }

  #loot-table.hide-col-severity th:nth-child(5),
  #loot-table.hide-col-severity td:nth-child(5),
  #loot-table.hide-col-severity col.c-sev { display: none !important; }

  #loot-table.hide-col-rule th:nth-child(6),
  #loot-table.hide-col-rule td:nth-child(6),
  #loot-table.hide-col-rule col.c-rule { display: none !important; }

  #loot-table.hide-col-keyword th:nth-child(7),
  #loot-table.hide-col-keyword td:nth-child(7),
  #loot-table.hide-col-keyword col.c-key { display: none !important; }

  #loot-table.hide-col-modified th:nth-child(8),
  #loot-table.hide-col-modified td:nth-child(8),
  #loot-table.hide-col-modified col.c-mod { display: none !important; }

  #loot-table.hide-col-unc th:nth-child(9),
  #loot-table.hide-col-unc td:nth-child(9),
  #loot-table.hide-col-unc col.c-unc { display: none !important; }

  #loot-table.hide-col-extension th:nth-child(10),
  #loot-table.hide-col-extension td:nth-child(10),
  #loot-table.hide-col-extension col.c-ext { display: none !important; }

  #loot-table.hide-col-actions th:nth-child(11),
  #loot-table.hide-col-actions td:nth-child(11),
  #loot-table.hide-col-actions col.c-actions { display: none !important; }

  #loot-table.hide-col-content th:nth-child(12),
  #loot-table.hide-col-content td:nth-child(12),
  #loot-table.hide-col-content col.c-content { display: none !important; }


  /* =========================
    Column visibility toggles
    ========================= */
  html.readable-on #loot-table td:nth-child(12) {
    white-space: pre-wrap !important;   /* show \n and \t */
    overflow: visible !important;
    text-overflow: clip !important;
  }


  /* =========================
     Row actions (icons + tooltips)
     ========================= */
  .row-actions {
    position: relative;
    z-index: 6;
    display: flex;
    gap: 6px;
    align-items: center;
    justify-content: center;
  }

  .row-actions .act {
    position: relative; /* tooltip anchor */
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.03);
    color: inherit;
    cursor: pointer;
    text-decoration: none; /* for <a> */
  }

  .row-actions .act:hover {
    background: rgba(255, 255, 255, 0.08);
    transform: scale(1.06);
  }

  /* Ensure the icon inside open/save links fits nicely */
  .row-actions .act .icon {
    width: auto;
    height: auto;
    font-size: 18px;
    line-height: 1;
  }

  /* Fade actions slightly until hover (cleaner scanning) */
  #loot-body tr .row-actions { opacity: 0.75; }
  #loot-body tr:hover .row-actions { opacity: 1; }

  /* Copy feedback */
  .row-actions .act.copied {
    border-color: rgba(46, 204, 113, 0.55);
    background: rgba(46, 204, 113, 0.12);
  }

  .row-actions .act .tip {
    position: absolute;
    top: -26px;
    left: 50%;
    transform: translateX(-50%);
    font-size: 11px;
    padding: 3px 6px;
    border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.14);
    background: rgba(0, 0, 0, 0.85);
    color: inherit;
    white-space: nowrap;
    opacity: 0;
    pointer-events: none;
    transition: opacity 120ms ease;
  }

  .row-actions .act.show-tip .tip {
    opacity: 1;
  }

  /* =========================
     Row state styles (workflow)
     ========================= */
  /* Invalid: red-tinted row */
  #loot-body tr.invalid td {
    background-color: rgba(180, 30, 30, 0.18) !important;
    opacity: 0.7;
  }

  /* Cred score row left-border: colour ramps from grey->yellow->orange->red */
  #loot-body tr.cred-low    { border-left: 3px solid #888; }
  #loot-body tr.cred-mid    { border-left: 3px solid #c8a000; }
  #loot-body tr.cred-high   { border-left: 3px solid #e06000; }
  #loot-body tr.cred-crit   { border-left: 3px solid #cc2020; }

  /* Done: greyed out */
  #loot-body tr.done td {
    opacity: 0.55;
  }

  #loot-body tr.done td a,
  #loot-body tr.done td .icon {
    opacity: 0.7;
  }

  /* Flagged: subtle overlay on every cell except severity */
  #loot-body tr.flagged td:not(:nth-child(5)) {
    background-color: inherit;
    position: relative;
  }

  #loot-body tr.flagged td:not(:nth-child(5))::after {
    content: "";
    position: absolute;
    inset: 0;
    background: rgba(245, 197, 66, 0.10);
    pointer-events: none;
    z-index: 0;
  }

  #loot-body tr.flagged td:not(:nth-child(5)) > * {
    position: relative;
    z-index: 1;
  }

  /* =========================
     Modals
     ========================= */
  .modal-overlay {
    position: fixed;
    inset: 0;
    display: none;
    align-items: center;
    justify-content: center;
    padding: 20px;
    background: rgba(0, 0, 0, 0.65);
    z-index: 5000;
  }

  .modal-overlay.open {
    display: flex;
  }

  .modal {
    width: min(900px, 95vw);
    max-height: 85vh;
    overflow: auto;
    border-radius: 12px;
    border: 1px solid #333;
    background: #1E1E1E;
    color: inherit;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
  }

  .modal-header {
    position: sticky;
    top: 0;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 14px;
    border-bottom: 1px solid #333;
    background: rgba(30, 30, 30, 0.95);
  }

  .modal-title {
    font-weight: 700;
    font-size: 16px;
  }

  .modal-close { margin-left: auto; }
  .modal-body { padding: 12px 14px; }

  /* =========================
     Content highlight classes
     ========================= */

  /* !! Real detected credential VALUE - bright and obvious !! */
  .hl-cred-found {
    background: #ffe600;
    color: #000 !important;
    font-weight: 700;
    border-radius: 3px;
    padding: 1px 3px;
    outline: 2px solid #ff8c00;
    box-shadow: 0 0 6px rgba(255,200,0,0.7);
  }

  html[data-theme="light"] .hl-cred-found {
    background: #ffe600;
    color: #000 !important;
    outline: 2px solid #cc6600;
  }



  /* Search highlights */
  mark.hit {
    padding: 0 2px;
    border-radius: 3px;
    background: rgba(255, 235, 59, 0.25);
    color: inherit;
  }

  /* =========================
     Bulk-invalid floating panel
     ========================= */
  #bulk-invalid-float {
    position: fixed;
    bottom: 24px;
    right: 24px;
    z-index: 4000;
    display: none;            /* shown via JS */
    flex-direction: column;
    width: 320px;
    border-radius: 10px;
    border: 1px solid #555;
    background: rgba(22, 22, 28, 0.97);
    box-shadow: 0 6px 28px rgba(0,0,0,0.55);
    backdrop-filter: blur(6px);
    font-size: 13px;
    overflow: hidden;
    resize: horizontal;
    min-width: 240px;
    max-width: 520px;
  }

  #bulk-invalid-float-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 9px 12px;
    background: rgba(40, 40, 50, 0.98);
    border-bottom: 1px solid #444;
    font-weight: 700;
    font-size: 13px;
    cursor: default;
    user-select: none;
  }

  #bulk-invalid-collapse {
    background: transparent;
    border: 1px solid #555;
    color: inherit;
    width: 22px;
    height: 22px;
    padding: 0;
    font-size: 14px;
    line-height: 1;
    border-radius: 5px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    margin: 0;
    transform: none;
    transition: background 0.15s;
  }

  #bulk-invalid-collapse:hover {
    background: rgba(255,255,255,0.1);
    transform: none;
  }

  #bulk-invalid-float-body {
    padding: 12px;
  }

  /* Light theme adjustments */
  html[data-theme="light"] #bulk-invalid-float {
    background: rgba(245, 245, 248, 0.98);
    border: 1px solid #ccc;
    box-shadow: 0 6px 28px rgba(0,0,0,0.18);
  }

  html[data-theme="light"] #bulk-invalid-float-header {
    background: rgba(230, 230, 235, 0.98);
    border-bottom: 1px solid #ccc;
  }

  html[data-theme="light"] #bulk-invalid-float #bulk-invalid-input {
    border: 1px solid #ccc;
    background: #fff;
    color: #111;
  }

  html[data-theme="light"] #bulk-invalid-float #bulk-invalid-scope {
    border: 1px solid #ccc;
    background: #fff;
    color: #111;
  }

  /* keyword match (Snaffler rule keyword) */
  .hl-keyword {
    color: #ff4444;
    font-weight: 600;
  }

  /* credentials / secrets */
  .hl-cred {
    color: #ff5555;
    background: rgba(255, 50, 50, 0.12);
    border-radius: 2px;
    padding: 0 1px;
    font-weight: 600;
  }

  /* connection strings / databases */
  .hl-conn {
    color: #ffaa33;
    background: rgba(255, 160, 40, 0.10);
    border-radius: 2px;
    padding: 0 1px;
  }

  /* network / infrastructure */
  .hl-net {
    color: #f0d050;
    background: rgba(240, 200, 50, 0.08);
    border-radius: 2px;
    padding: 0 1px;
  }

  /* cloud / SaaS */
  .hl-cloud {
    color: #44dddd;
    background: rgba(40, 200, 200, 0.08);
    border-radius: 2px;
    padding: 0 1px;
  }

  /* hashes / base64 blobs */
  .hl-hash {
    color: #bb88ff;
    background: rgba(170, 100, 255, 0.08);
    border-radius: 2px;
    padding: 0 1px;
    font-family: monospace;
    font-size: 0.92em;
  }

  /* light theme adjustments */
  html[data-theme="light"] .hl-keyword { color: #cc0000; }
  html[data-theme="light"] .hl-cred    { color: #cc0000; background: rgba(200, 0, 0, 0.08); }
  html[data-theme="light"] .hl-conn    { color: #b85c00; background: rgba(200, 120, 0, 0.08); }
  html[data-theme="light"] .hl-net     { color: #8a6e00; background: rgba(180, 150, 0, 0.07); }
  html[data-theme="light"] .hl-cloud   { color: #007a7a; background: rgba(0, 150, 150, 0.07); }
  html[data-theme="light"] .hl-hash    { color: #6600cc; background: rgba(100, 0, 200, 0.06); }

  .cred-score-cell {
    text-align: center;
    vertical-align: middle;
    font-size: 12px;
    font-weight: 700;
    font-family: monospace;
  }
  .cred-score-0  { color: #555; }
  .cred-score-lo { color: #888; }
  .cred-score-md { color: #c8a000; }
  .cred-score-hi { color: #e06000; }
  .cred-score-cr { color: #cc2020; }

  /* =========================
     Toast notification
     ========================= */
  #snaffler-toast {
    position: fixed;
    bottom: 28px;
    left: 50%;
    transform: translateX(-50%) translateY(20px);
    background: rgba(30, 30, 30, 0.95);
    color: #e0e0e0;
    border: 1px solid #444;
    border-radius: 8px;
    padding: 10px 20px;
    font-size: 13px;
    opacity: 0;
    pointer-events: none;
    transition: opacity 200ms ease, transform 200ms ease;
    z-index: 9000;
    white-space: nowrap;
  }

  #snaffler-toast.show {
    opacity: 1;
    transform: translateX(-50%) translateY(0);
  }

  /* =========================
     Light theme overrides
     ========================= */
  html[data-theme="light"] body {
    background: #ffffff;
    color: #111;
  }

  html[data-theme="light"] h1,
  html[data-theme="light"] h2 {
    color: #000099;
  }

  html[data-theme="light"] table {
    background: #fff;
    color: #111;
  }

  html[data-theme="light"] th {
    background: linear-gradient(#49708f, #293f50);
    color: #fff;
    border: 1px solid #ccc;
    border-bottom: 2px solid #ccc;
  }

  html[data-theme="light"] td {
    border: 1px solid #ddd;
  }

  html[data-theme="light"] tbody tr:nth-child(even) { background: #f0f0f2; }
  html[data-theme="light"] tbody tr:nth-child(odd) { background: #ffffff; }

  html[data-theme="light"] tbody tr:hover td:not(:nth-child(5)) {
    background-color: lightblue !important;
  }

  html[data-theme="light"] #report-header {
    background: rgba(255, 255, 255, 0.92);
    border-bottom: 1px solid #ccc;
  }

  html[data-theme="light"] #filter-menu { border: 1px solid #ccc; }
  html[data-theme="light"] details.filter-card { border: 1px solid #ccc; }

  html[data-theme="light"] .filter-topbar input[type="text"],
  html[data-theme="light"] .ext-search {
    border: 1px solid #ccc;
    background: #fff;
    color: #111;
  }

  html[data-theme="light"] .hdr-link {
    border: 1px solid #ccc;
    background: #fff;
  }

  html[data-theme="light"] .hdr-sub .sev.black {
    color: #111;
  }

  html[data-theme="light"] mark.hit {
    background: rgba(255, 235, 59, 0.55);
  }

  html[data-theme="light"] .modal {
    background: #fff;
    border: 1px solid #ccc;
  }

  html[data-theme="light"] .modal-header {
    background: rgba(255, 255, 255, 0.95);
    border-bottom: 1px solid #ccc;
  }
</style>

"@


# ---------------- HTML skeleton (NO huge table) ----------------
$titleAndTable = @"
<div id="report-header">
  <div class="hdr-left">
    <span id="report-sha256" style="display:none;">$($baseInfo.SHA256)</span>
    <div class="hdr-title">
      <span class="hdr-name">SnafflerParser Loot Report</span>
    </div>
    <div class="hdr-sub">
      <span class="hdr-meta">Input: <strong>$($baseInfo.Snaffler_File)</strong></span>
      <span class="hdr-dot">&#8226;</span>
      <span class="hdr-meta">Files: <strong>$filesum</strong></span>
      <span class="hdr-dot">&#8226;</span>
      <span class="hdr-meta sev black">B: <strong>$blackscount</strong></span>
      <span class="hdr-meta sev red">R: <strong>$redscount</strong></span>
      <span class="hdr-meta sev yellow">Y: <strong>$yellowscount</strong></span>
      <span class="hdr-meta sev green">G: <strong>$greenscount</strong></span>
      <span class="hdr-dot">&#8226;</span>
      <span class="hdr-meta">Parsed: <strong>$(Format-TimePrettyUtc $baseInfo.Report_GeneratedUtc)</strong></span>

    </div>
  </div>

  <div class="hdr-right">
    <a class="hdr-link" href="https://github.com/zh54321/snaffler_parser" target="_blank" rel="noopener">
      Repo &#8599;
    </a>
    <button id="show-input-info" type="button">Job Info</button>
    <button id="save-html" type="button">Save HTML</button>
    <button id="theme-toggle" type="button" title="Toggle theme">Light mode</button>
  </div>
</div>


<div id="filter-menu"></div>

<div id="pager" style="margin:10px 0; display:flex; gap:10px; align-items:center; flex-wrap:wrap;">
  <button id="prevPage">Prev</button>
  <button id="nextPage">Next</button>
  <span id="pageInfo"></span>
  <label style="display:inline-flex; align-items:center; gap:6px;">
    Go to:
    <input id="pageJump" type="number" min="1" step="1"
           style="width:90px; padding:6px 8px; border-radius:8px; border:1px solid #444; background: rgba(255,255,255,0.03); color: inherit;"
           aria-label="Go to page">
  </label>
  <button id="pageJumpGo" type="button" title="Go to page">Go</button>
  <label>Rows/page:
    <select id="pageSize">
      <option>100</option>
      <option>250</option>
      <option selected>500</option>
      <option>1000</option>
      <option>5000</option>
    </select>
  </label>

  <span style="margin-left:auto;"></span>
  <button id="cols-btn" type="button" title="Choose visible columns">Columns</button>
  <button id="toggle-readable" type="button" title="Toggle readable content">Unescape</button>
  <button id="bulk-invalid-btn" type="button" title="Mark rows matching a string as invalid">&#10060; Bulk Mark Invalid</button>
  <button id="reset-progress" type="button" title="Delete saved check/done state">Reset Progress</button>
  <button id="export-csv" type="button" title="Export current filtered view to CSV">Export Filtered Table</button>
</div>

<div id="bulk-invalid-float" aria-label="Bulk Mark Invalid panel">
  <div id="bulk-invalid-float-header">
    <span>&#10060; Bulk Mark Invalid</span>
    <button id="bulk-invalid-collapse" type="button" title="Collapse panel">&#8211;</button>
  </div>
  <div id="bulk-invalid-float-body">
    <div style="display:flex; gap:6px; align-items:center; flex-wrap:wrap; margin-bottom:8px;">
      <input id="bulk-invalid-input" type="text" placeholder="String to match..."
             style="flex:1; min-width:140px; padding:7px 9px; border-radius:7px; border:1px solid #555; background:rgba(255,255,255,0.05); color:inherit; font-size:12px;">
      <select id="bulk-invalid-scope"
              style="padding:7px 8px; border-radius:7px; border:1px solid #555; background:rgba(30,30,30,0.97); color:inherit; font-size:12px; cursor:pointer;">
        <option value="all">All fields</option>
        <option value="unc">UNC path</option>
        <option value="content">Content</option>
        <option value="rule">Rule</option>
        <option value="keyword">Keyword</option>
      </select>
    </div>
    <div id="bulk-invalid-count" style="font-size:11px; min-height:16px; margin-bottom:8px; opacity:0.85;"></div>
    <div style="display:flex; gap:8px; flex-wrap:wrap;">
      <button id="bulk-invalid-apply" type="button" style="font-size:12px; padding:7px 10px;">&#10060; Mark Invalid</button>
      <button id="bulk-invalid-clear" type="button" style="font-size:12px; padding:7px 10px; background:rgba(160,40,40,0.8);">Clear All</button>
    </div>
  </div>
</div>

<div id="cols-modal" class="modal-overlay" aria-hidden="true">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">Visible Columns</div>
      <button id="cols-close" class="modal-close" type="button">Close</button>
    </div>
    <div class="modal-body">
      <div id="cols-list" class="filter-list threecol"></div>

      <div class="filter-actions-row" style="margin-top:12px;">
        <button id="cols-all" type="button">All</button>
        <button id="cols-none" type="button">None</button>
        <button id="cols-apply" type="button">Apply</button>
      </div>
    </div>
  </div>
</div>



<table id="loot-table">
  <colgroup>
    <col class="c-check">
    <col class="c-done">
    <col class="c-invalid">
    <col class="c-cred">
    <col class="c-sev">
    <col class="c-rule">
    <col class="c-key">
    <col class="c-mod">
    <col class="c-unc">
    <col class="c-ext">
    <col class="c-actions">
    <col class="c-content">
  </colgroup>
  <thead>
    <tr>
      <th data-col="check"     title="Flag">&#9733;</th>
      <th data-col="done"      title="Reviewed">&#10003;</th>
      <th data-col="invalid"   title="Invalid">&#10060;</th>
      <th data-col="credScore" title="Likely real credential detected">&#128273;</th>
      <th data-col="severity">severity</th>
      <th data-col="rule">rule</th>
      <th data-col="keyword">keyword</th>
      <th data-col="modified">modified</th>
      <th data-col="unc">unc</th>
      <th data-col="extension">extension</th>
      <th data-col="actions">actions</th>
      <th data-col="content">content</th>
    </tr>
  </thead>
  <tbody id="loot-body"></tbody>
</table>
"@


# ---------------- Build JSON blob from the PS objects ----------------
$rowsForJson = $object | ForEach-Object {
    [pscustomobject]@{
        severity  = $_.severity
        rule      = $_.rule
        keyword   = $_.keyword
        modified  = $_.modified
        unc       = $_.unc
        extension = $_.extension
        content   = $_.content
        check     = $false
        done      = $false
        invalid   = $false
        credScore = [int]$_.credScore
    }
}

$json = $rowsForJson | ConvertTo-Json -Depth 6 -Compress
$json = $json -replace '</script', '<\/script'
$dataBlob = "<script id='loot-data' type='application/json'>$json</script>"

# ---------------- Compose & write final HTML ----------------
write-host "[*] Storing: $($outputname)_loot_$($name).html"

# ---- Parse Snaffler Finished + Duration into objects (so we can pretty print consistently) ----
$finishedObj = $null
if ($baseInfo.Snaffler_EndTime) {
  try {
    # "21/01/2025 07:30:59" (assumed local machine time)
    $finishedObj = [DateTime]::ParseExact(
      $baseInfo.Snaffler_EndTime,
      'dd/MM/yyyy HH:mm:ss',
      [System.Globalization.CultureInfo]::InvariantCulture
    )
  } catch {
    $finishedObj = $baseInfo.Snaffler_EndTime # fallback string
  }
}

$durationObj = $null
if ($baseInfo.Snaffler_Duration) {
  try { $durationObj = [TimeSpan]::Parse($baseInfo.Snaffler_Duration) } catch { $durationObj = $null }
}

# ---- Ordered modal content (controls display order) ----
$baseInfoForModal = [pscustomobject]@{
  'Input file'        = $baseInfo.Snaffler_File
  'SHA256'            = $baseInfo.SHA256
  'Computer'          = $baseInfo.Snaffler_ComputerName
  'User'              = $baseInfo.Snaffler_User

  'Started'           = (Format-TimePrettyUtc $baseInfo.Snaffler_StartTime)
  'Finished'          = (Format-TimePrettyUtc $finishedObj)
  'Snaffler duration' = (Format-DurationPretty $durationObj)

  'Report generated'  = (Format-TimePrettyUtc $baseInfo.Report_GeneratedUtc)
  'Parser duration'   = (Format-DurationPretty $baseInfo.Parser_Duration)
  'Input format'      = $baseInfo.Input_Format
  'Files parsed'      = $baseInfo.Input_Files
  'Domain hint'       = if ($domain -ne '') { $domain } else { '(none)' }
}

$inputInfoInner = $baseInfoForModal | ConvertTo-Html -As List -Fragment




$inputInfo = @"
<div id="input-info-modal" class="modal-overlay" aria-hidden="true">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">Input Information</div>
      <button id="modal-close" class="modal-close" type="button">Close</button>
    </div>
    <div class="modal-body">
      $inputInfoInner
    </div>
  </div>
</div>
"@


# Put inputInfo + skeleton table + json blob into body
$body = "$inputInfo $titleAndTable $dataBlob"

$htmlOutput = ConvertTo-Html -Head $css,$Header -Body $body

$htmlOutput | Out-File -FilePath "$($outputname)_loot_$($name).html" -Encoding UTF8

}


# Script section-----------------------------------------------------------------------------------

$banner = @"
 ____               __  __ _             ____                          
/ ___| _ __   __ _ / _|/ _| | ___ _ __  |  _ \ __ _ _ __ ___  ___ _ __ 
\___ \|  _ \ / _  | |_| |_| |/ _ \ '__| | |_) / _  | '__/ __|/ _ \ '__|
 ___) | | | | (_| |  _|  _| |  __/ |    |  __/ (_| | |  \__ \  __/ |   
|____/|_| |_|\__,_|_| |_| |_|\___|_|    |_|   \__,_|_|  |___/\___|_|   

"@

Write-Host $banner -ForegroundColor Cyan

$parserStart = [DateTimeOffset]::UtcNow

# ── Help screen ─────────────────────────────────────────────────────────────
# Show if: -help / -h / -? / --help passed, OR no meaningful input specified
$noInputSupplied = ($in -eq '') -and ($ins.Count -eq 0) -and ($indir -eq '') -and (-not $snaffel) -and (-not $gridviewload)
$helpRequested   = $help -or $h -or $question

if ($helpRequested -or $noInputSupplied) {
    Write-Host ""
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  .\snafflerParser.ps1 -in <file> [options]"
    Write-Host "  .\snafflerParser.ps1 -ins <file1>,<file2> [options]"
    Write-Host "  .\snafflerParser.ps1 -indir <folder> [options]"
    Write-Host ""
    Write-Host "INPUT" -ForegroundColor Yellow
    Write-Host "  -in     <path>      Single Snaffler log file (default: snafflerout.txt)"
    Write-Host "  -ins    <p1>,<p2>   Comma-separated list of log files (deduplicates across files)"
    Write-Host "  -indir  <folder>    Parse all .log/.txt files in a directory"
    Write-Host ""
    Write-Host "OUTPUT" -ForegroundColor Yellow
    Write-Host "  -outformat <fmt>    Output format: default | all | csv | txt | json | html"
    Write-Host "                        default = CSV + TXT + HTML"
    Write-Host "                        all     = CSV + TXT + HTML + JSON"
    Write-Host "  -sort   <field>     Sort by: modified (default) | keyword | rule | unc"
    Write-Host "  -split              Also write per-severity files (black/red/yellow/green)"
    Write-Host ""
    Write-Host "SCORING" -ForegroundColor Yellow
    Write-Host "  -domain <name>      Domain keyword (e.g. CORP) for boosted credential scoring:"
    Write-Host "                        Score 1 = real-looking credential value"
    Write-Host "                        Score 2 = + domain context (@CORP, CORP\user, UNC path)"
    Write-Host "                        Score 3 = + service account (svc-, sa-, CORP\svc*)"
    Write-Host ""
    Write-Host "INTERACTIVE" -ForegroundColor Yellow
    Write-Host "  -gridview           Show results in PowerShell GridView after parsing"
    Write-Host "  -gridviewload       Load a previously saved GridView CSV"
    Write-Host "  -gridin <path>      GridView CSV to load (default: snafflerout.txt_loot_gridview.csv)"
    Write-Host "  -pte                Export shares as Explorer++ bookmarks"
    Write-Host "  -snaffel            Run Snaffler.exe first, then parse output"
    Write-Host ""
    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Host "  .\snafflerParser.ps1 -in snaffler.log"
    Write-Host "  .\snafflerParser.ps1 -in snaffler.log -domain CORP"
    Write-Host "  .\snafflerParser.ps1 -ins scan1.log,scan2.log -domain CONTOSO -outformat all"
    Write-Host "  .\snafflerParser.ps1 -indir C:\logs\snaffler -domain CORP -split"
    Write-Host "  .\snafflerParser.ps1 -in snaffler.log -sort unc -outformat csv"
    Write-Host ""
    if ($noInputSupplied -and -not $helpRequested) {
        Write-Host "  No input file specified. Use -in, -ins, or -indir to provide Snaffler output." -ForegroundColor Red
        Write-Host "  Run with -h for full help." -ForegroundColor DarkGray
        Write-Host ""
    }
    exit
}

if ($snaffel) {
	.\Snaffler.exe -o snafflerout.txt -s -y
}

# Check if gridviewfile should be loaded
if ($gridviewload) {
	gridview load
}

# =========================================================================
# Multi-file input: validate, deduplicate, parse all files
# =========================================================================

# Streaming containers (shared across all files)
$files     = [System.Collections.Generic.List[object]]::new()
$sharesSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$seenUncs  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# baseInfo tracks the first (or only) file; for multi-file runs we collect all filenames
$baseInfo = [PsCustomObject]@{
    Snaffler_File     = ($inputFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
    SHA256            = ''
    Snaffler_EndTime  = $null
    Snaffler_Duration = $null
    Input_Format      = $null
    Input_Files       = $inputFiles.Count
}

# Regex for bracket-format [File] lines (Snaffler without -y).
$regexFile  = [regex]'\[File\]\s+\{(?<severity>[^}]+)\}<(?<rule>[^|]+)\|[^|]*\|(?<keyword>[^|]+)\|(?<size>[^|]+)\|(?<modified>[^>]+)>\((?<unc>\\\\[^)]+)\)\s*(?<content>.*)'

# Regex for bracket-format [Share] lines.
$regexShare = [regex]'\[Share\]\s+[^(]*\((?<unc>\\\\[^)]+)\)'

# Header pattern shared by both formats
$headerPattern = '\[(?<machine>[^\\]+)\\(?<user>[^@]+)@[^\]]+\]\s+(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z?)'

$totalDupes = 0
$fileIndex  = 0

foreach ($currentFile in $inputFiles) {

    $fileIndex++

    # ---- Validate file ----
    write-host ""
    write-host "[*] [$fileIndex/$($inputFiles.Count)] Checking: $currentFile"

    if (!(Test-Path -LiteralPath $currentFile -PathType Leaf)) {
        write-host "[-] File not found, skipping: $currentFile"
        continue
    }

    $FileSize = (Get-ChildItem $currentFile).Length / 1014
    $FileSizeRound = [math]::Round($FileSize, 2)

    if ($FileSizeRound -lt 0.3) {
        write-host "[!] File too small (<0.3 KB), skipping: $currentFile"
        continue
    }

    write-host "[+] File is $FileSizeRound KB"

    # ---- SHA256 (first file drives the output name and hash) ----
    if ($fileIndex -eq 1) {
        $baseInfo.SHA256 = (Get-FileHash $currentFile).Hash
        $outputname = (Get-Item $currentFile).BaseName
        if ($inputFiles.Count -gt 1) { $outputname += "_combined" }
    }

    # ---- Detect format from first line ----
    $firstLine = Get-Content $currentFile -TotalCount 1
    $isTSV = $firstLine -match "`t"

    if ($isTSV) {
        write-host "[+] Format: TSV (Snaffler -y)"
        if ($null -eq $baseInfo.Input_Format) { $baseInfo.Input_Format = "TSV (Snaffler -y)" }
    } else {
        write-host "[+] Format: bracket (Snaffler without -y)"
        if ($null -eq $baseInfo.Input_Format) { $baseInfo.Input_Format = "bracket (Snaffler without -y)" }
    }

    # ---- Extract machine/user/time from header (first file wins) ----
    if ($fileIndex -eq 1 -and $firstLine -match $headerPattern) {
        $baseInfo | Add-Member -NotePropertyName Snaffler_ComputerName -NotePropertyValue $matches['machine']
        $baseInfo | Add-Member -NotePropertyName Snaffler_User         -NotePropertyValue $matches['user']
        $baseInfo | Add-Member -NotePropertyName Snaffler_StartTime    -NotePropertyValue $matches['timestamp']
    }

    # ---- Stream parse ----
    if ($domain -ne '') {
	write-host "[+] Domain hint: $domain (will boost score for domain-context credentials)"
} else {
	write-host "[i] No domain hint supplied (-domain). Domain-context scoring disabled."
}
write-host "[*] Streaming parse of input file"
    $fileDupes = 0
    $fileAdded = 0

    $sr = [System.IO.StreamReader]::new($currentFile)
    try {
        while (-not $sr.EndOfStream) {
            $raw = $sr.ReadLine()
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }

            # ==============================================================
            # TSV FORMAT (Snaffler -y)
            # ==============================================================
            if ($isTSV) {

                $cols = $raw.Split("`t", [System.StringSplitOptions]::None)
                if ($cols.Length -lt 3) { continue }
                $typ = $cols[2]

                if ($typ -eq "[Info]" -and $cols.Length -ge 4) {
                    $msg = $cols[3]
                    if ($msg -like "Finished at*") {
                        if ($msg -match '^Finished at\s+(?<dt>\d{1,2}/\d{1,2}/\d{4}\s+\d{2}:\d{2}:\d{2})') {
                            $baseInfo.Snaffler_EndTime = $Matches.dt
                        } else { $baseInfo.Snaffler_EndTime = $msg }
                        continue
                    }
                    if ($msg -like "Snafflin'*took*") {
                        if ($msg -match "took\s+(?<dur>\d{2}:\d{2}:\d{2}(?:\.\d+)?)") {
                            $baseInfo.Snaffler_Duration = $Matches.dur
                        } else { $baseInfo.Snaffler_Duration = $msg }
                        continue
                    }
                }

                if ($typ -eq "[Share]") {
                    if ($cols.Length -gt 4) {
                        $shareUnc = $cols[4]
                        if (-not [string]::IsNullOrWhiteSpace($shareUnc)) { [void]$sharesSet.Add($shareUnc) }
                    }
                    continue
                }

                if ($typ -eq "[File]") {
                    if ($cols.Length -lt 12) { continue }
                    $unc = $cols[11]
                    if ([string]::IsNullOrWhiteSpace($unc)) { continue }

                    # Deduplicate across files
                    if (-not $seenUncs.Add($unc)) { $fileDupes++; continue }

                    $content = if ($cols.Length -gt 12) { $cols[12] } else { '' }
                    $uncSafe = $unc -replace '[\x00-\x1F]', ''
                    if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
                        $uncSafe = $uncSafe -replace '[<>:"|?*]', ''
                    }
                    $ext = ''
                    try { $ext = [System.IO.Path]::GetExtension($uncSafe) } catch { $ext = '' }

                    $files.Add([PsCustomObject]@{
                        check     = $false
                        done      = $false
                        invalid   = $false
                        severity  = if ($cols.Length -gt 3)  { $cols[3] }  else { '' }
                        rule      = if ($cols.Length -gt 4)  { $cols[4] }  else { '' }
                        keyword   = if ($cols.Length -gt 8)  { $cols[8] }  else { '' }
                        modified  = if ($cols.Length -gt 10) { $cols[10] } else { '' }
                        unc       = $unc
                        extension = $ext
                        content   = $content
                        credScore = Get-CredScore -text $content -domainHint $domain -uncPath $unc
                    })
                    $fileAdded++
                }

            # ==============================================================
            # BRACKET FORMAT (Snaffler without -y)
            # ==============================================================
            } else {

                if ($raw -match '\[Info\]') {
                    if ($raw -match 'Finished\s+at\s+(?<dt>\d{1,2}/\d{1,2}/\d{4}\s+\d{2}:\d{2}:\d{2})') {
                        $baseInfo.Snaffler_EndTime = $Matches.dt
                    } elseif ($raw -match "took\s+(?<dur>\d{2}:\d{2}:\d{2}(?:\.\d+)?)") {
                        $baseInfo.Snaffler_Duration = $Matches.dur
                    }
                    continue
                }

                if ($raw -match '\[Share\]') {
                    $m = $regexShare.Match($raw)
                    if ($m.Success) {
                        $shareUnc = $m.Groups['unc'].Value.TrimEnd('\')
                        if (-not [string]::IsNullOrWhiteSpace($shareUnc)) { [void]$sharesSet.Add($shareUnc) }
                    }
                    continue
                }

                if ($raw -match '\[File\]') {
                    $m = $regexFile.Match($raw)
                    if (-not $m.Success) { continue }

                    $unc = $m.Groups['unc'].Value
                    if ([string]::IsNullOrWhiteSpace($unc)) { continue }

                    # Deduplicate across files
                    if (-not $seenUncs.Add($unc)) { $fileDupes++; continue }

                    $uncSafe = $unc -replace '[\x00-\x1F]', ''
                    $ext = ''
                    try { $ext = [System.IO.Path]::GetExtension($uncSafe) } catch { $ext = '' }

                    $files.Add([PsCustomObject]@{
                        check     = $false
                        done      = $false
                        invalid   = $false
                        severity  = $m.Groups['severity'].Value
                        rule      = $m.Groups['rule'].Value
                        keyword   = $m.Groups['keyword'].Value
                        modified  = $m.Groups['modified'].Value
                        unc       = $unc
                        extension = $ext
                        content   = $m.Groups['content'].Value
                        credScore = Get-CredScore -text $m.Groups['content'].Value -domainHint $domain -uncPath $unc
                    })
                    $fileAdded++
                }
            }
        }
    }
    finally {
        if ($null -ne $sr) { $sr.Dispose() }
    }

    write-host "[+] File parsed: $fileAdded unique entries added, $fileDupes duplicates skipped"
    $totalDupes += $fileDupes
}

if ($inputFiles.Count -gt 1) {
    write-host ""
    write-host "[+] Combined totals: $($files.Count) unique entries across $($inputFiles.Count) files ($totalDupes duplicates removed)"
}

write-host "[*] Processing shares"

$shares = $sharesSet |
    ForEach-Object { [PsCustomObject]@{ unc = $_ } } |
    Sort-Object -Property unc



# Check share count and write to file
$sharescount = $shares | Measure-Object -Line -Property unc
if ($sharescount.lines -ge 1) {
	write-host "[+] Shares identified: $($sharescount.lines)"
	write-host "[*] Writing share output file"
	$shares | Format-Table -AutoSize | Out-File -FilePath "$($outputname)_shares.txt"
} else {
	write-host "[!] Shares identified: 0"
	if ($isTSV) {
		write-host "[?] Was Snaffler executed with parameter -y ?"
	} else {
		write-host "[i] Log4net format: share enumeration output may vary by Snaffler version"
	}
}



# Define fixed severity order
$severityRank = @{
    Black  = 0
    Red    = 1
    Yellow = 2
    Green  = 3
}

# Whether to sort descending
$sortDescending = ($sort -eq 'modified')

# Sort once:
# 1) by severity rank so Black/Red/Yellow/Green always stay grouped + ordered
# 2) then by chosen $sort column (descending only for modified)
$fulloutput = $files | Sort-Object `
    @{ Expression = { $severityRank[$_.severity] } ; Ascending = $true } ,
    @{ Expression = { $_.$sort } ; Descending = $sortDescending }

# Group once into a hashtable: keys = "Black"/"Red"/...
# Guard: Group-Object returns $null when input is empty, causing indexing to crash
if ($fulloutput) {
    $bySeverity = $fulloutput | Group-Object -Property severity -AsHashTable -AsString
} else {
    $bySeverity = @{}
}

# Pull groups out (always define them as arrays, even if empty)
$blacks  = if ($bySeverity -and $bySeverity['Black'])  { @($bySeverity['Black'])  } else { @() }
$reds    = if ($bySeverity -and $bySeverity['Red'])    { @($bySeverity['Red'])    } else { @() }
$yellows = if ($bySeverity -and $bySeverity['Yellow']) { @($bySeverity['Yellow']) } else { @() }
$greens  = if ($bySeverity -and $bySeverity['Green'])  { @($bySeverity['Green'])  } else { @() }

# Counts
$blackscount  = $blacks.Count
$redscount    = $reds.Count
$yellowscount = $yellows.Count
$greenscount  = $greens.Count



$filesum = $blackscount + $redscount + $yellowscount + $greenscount
if ($filesum -ge 1) {
	write-host "[+] Files total: $filesum "
	write-host "[+] Files with severity BLACK: $blackscount"
	write-host "[+] Files with severity RED: $redscount"
	write-host "[+] Files with severity YELLOW: $yellowscount"
	write-host "[+] Files with severity GREEN: $greenscount"


  $reportGeneratedUtc = [DateTimeOffset]::UtcNow
  $parserDuration = $reportGeneratedUtc - $parserStart

  $baseInfo | Add-Member -NotePropertyName Report_GeneratedUtc -NotePropertyValue $reportGeneratedUtc -Force
  $baseInfo | Add-Member -NotePropertyName Parser_Duration -NotePropertyValue $parserDuration -Force

  
	#Write outputs depening on desired format
	if ($outformat -eq "all"){
		write-host "[*] Exporting full CSV + TXT + JSON + HTML"
		exporttxt $fulloutput full
		exportcsv $fulloutput full
		exportjson $fulloutput full
		exporthtml $fulloutput full
		if ($split) {
			write-host "[*] Exporting splitted CSV + TXT"
			if ($blackscount -ge 1) {exportcsv $blacks blacks}
			if ($redscount -ge 1) {exportcsv $reds reds}
			if ($yellowscount -ge 1) {exportcsv $yellows yellows}
			if ($greenscount -ge 1) {exportcsv $greens greens}
			if ($blackscount -ge 1) {exporttxt $blacks blacks}
			if ($redscount -ge 1) {exporttxt $reds reds}
			if ($yellowscount -ge 1) {exporttxt $yellows yellows}
			if ($greenscount -ge 1) {exporttxt $greens greens}
			if ($blackscount -ge 1) {exportjson $blacks blacks}
			if ($redscount -ge 1) {exportjson $reds reds}
			if ($yellowscount -ge 1) {exportjson $yellows yellows}
			if ($greenscount -ge 1) {exportjson $greens greens}
			if ($blackscount -ge 1) {exporthtml $blacks blacks}
			if ($redscount -ge 1) {exporthtml $reds reds}
			if ($yellowscount -ge 1) {exporthtml $yellows yellows}
			if ($greenscount -ge 1) {exporthtml $greens greens}
		}
	} elseif ($outformat -eq "default") {
		write-host "[*] Exporting full CSV + TXT + HTML"
		exporttxt $fulloutput full
		exportcsv $fulloutput full
		exporthtml $fulloutput full
		if ($split) {
			write-host "[*] Exporting splitted CSV + TXT"
			if ($blackscount -ge 1) {exportcsv $blacks blacks}
			if ($redscount -ge 1) {exportcsv $reds reds}
			if ($yellowscount -ge 1) {exportcsv $yellows yellows}
			if ($greenscount -ge 1) {exportcsv $greens greens}
			if ($blackscount -ge 1) {exporttxt $blacks blacks}
			if ($redscount -ge 1) {exporttxt $reds reds}
			if ($yellowscount -ge 1) {exporttxt $yellows yellows}
			if ($greenscount -ge 1) {exporttxt $greens greens}
			if ($blackscount -ge 1) {exporthtml $blacks blacks}
			if ($redscount -ge 1) {exporthtml $reds reds}
			if ($yellowscount -ge 1) {exporthtml $yellows yellows}
			if ($greenscount -ge 1) {exporthtml $greens greens}
		}
	} elseif ($outformat -eq "txt") {
		write-host "[*] Exporting full TXT"
		exporttxt $fulloutput full

		if ($split) {
			write-host "[*] Exporting splitted TXT"
			if ($blackscount -ge 1) {exporttxt $blacks blacks}
			if ($redscount -ge 1) {exporttxt $reds reds}
			if ($yellowscount -ge 1) {exporttxt $yellows yellows}
			if ($greenscount -ge 1) {exporttxt $greens greens}
		}
	} elseif ($outformat -eq "csv") {
		write-host "[*] Exporting full CSV"
		exportcsv $fulloutput full
		if ($split) {
			write-host "[*] Exporting splitted CSV"
			if ($blackscount -ge 1) {exportcsv $blacks blacks}
			if ($redscount -ge 1) {exportcsv $reds reds}
			if ($yellowscount -ge 1) {exportcsv $yellows yellows}
			if ($greenscount -ge 1) {exportcsv $greens greens}
		}
	} elseif ($outformat -eq "json") {
		write-host "[*] Exporting full JSON"
		exportjson $fulloutput full
		if ($split) {
			write-host "[*] Exporting splitted JSON"
			if ($blackscount -ge 1) {exportjson $blacks blacks}
			if ($redscount -ge 1) {exportjson $reds reds}
			if ($yellowscount -ge 1) {exportjson $yellows yellows}
			if ($greenscount -ge 1) {exportjson $greens greens}
		}
	} elseif ($outformat -eq "html") {
		write-host "[*] Exporting full HTML"
		exporthtml $fulloutput full
		if ($split) {
			write-host "[*] Exporting splitted HTML"
			if ($blackscount -ge 1) {exporthtml $blacks blacks}
			if ($redscount -ge 1) {exporthtml $reds reds}
			if ($yellowscount -ge 1) {exporthtml $yellows yellows}
			if ($greenscount -ge 1) {exporthtml $greens greens}
		}
	}
} else {
	# Error handling if no files detected
	write-host "[!] Something is wrong. Number of files identified: $filesum"
	if ($isTSV) {
		write-host "[?] Was Snaffler executed with parameter -y ?"
	} else {
		write-host "[i] Log4net format detected. Verify the file is valid Snaffler output."
		write-host "[i] Expected line format: TIMESTAMP [Snaffler] INFO  Snaffler  [File] Severity {Rule} (keyword) \\unc\path <modified> (size) <.ext> [content]"
	}
	exit
}
# Start grid view if desired
if ($gridview) {
	gridview start
}

# Check if shares should be exported as bookmarks to Explorer++
if ($pte) {
	write-host "[*] Will export $($sharescount.lines) shares to explorer"
	explorerpp($shares)
}