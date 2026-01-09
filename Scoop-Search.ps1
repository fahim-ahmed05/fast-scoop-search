<#
.SYNOPSIS
    Fast search for Scoop packages using JSON index.

.DESCRIPTION
    This script creates and maintains a local JSON index of all Scoop packages.
    Search is lightning fast using in-memory cache, and the index auto-updates when empty or no results found.
    Index is grouped by bucket with embedded git hashes for efficient incremental updates.

.PARAMETER PackageName
    The package name to search for

.EXAMPLE
    .\Scoop-Search.ps1 python
    Searches for packages matching "python"

.EXAMPLE
    .\Scoop-Search.ps1 stremio
    Searches for packages matching "stremio"
#>

param(
    [Parameter(Position=0, Mandatory=$false)]
    [string]$PackageName
)

# Configuration
$script:ScoopDir = $env:SCOOP
if (-not $script:ScoopDir) {
    $script:ScoopDir = "$env:USERPROFILE\scoop"
}

$script:BucketsDir = Join-Path $script:ScoopDir "buckets"
$script:IndexFile = Join-Path $PSScriptRoot "scoop-index.json"

# In-memory flattened cache for fast searching
$script:PackageCache = $null

#region Helper Functions

function Read-PackageIndex {
    <#
    .SYNOPSIS
        Reads the grouped package index from JSON file
        Returns: @{ bucket = @{ hash = "...", packages = @{ name = version } } }
    #>
    if (Test-Path $script:IndexFile) {
        try {
            $json = Get-Content $script:IndexFile -Raw -Encoding UTF8
            return ($json | ConvertFrom-Json -AsHashtable)
        }
        catch {
            Write-Verbose "Failed to read package index: $_"
            return @{}
        }
    }
    return @{}
}

function Get-FlattenedCache {
    <#
    .SYNOPSIS
        Flattens grouped index into "bucket/package" = "version" hashtable for fast search
    #>
    param(
        [hashtable]$GroupedIndex
    )
    
    $flattened = @{}
    foreach ($bucket in $GroupedIndex.Keys) {
        $packages = $GroupedIndex[$bucket].packages
        if ($packages) {
            foreach ($pkg in $packages.Keys) {
                $flattened["$bucket/$pkg"] = $packages[$pkg]
            }
        }
    }
    return $flattened
}

function Write-PackageIndex {
    <#
    .SYNOPSIS
        Writes the grouped package index hashtable to JSON file
    #>
    param(
        [hashtable]$GroupedIndex
    )
    
    try {
        $GroupedIndex | ConvertTo-Json -Depth 4 -Compress | Set-Content $script:IndexFile -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to write package index: $_"
    }
}

function Initialize-Database {
    <#
    .SYNOPSIS
        Creates package index file if it doesn't exist
    #>
    if (-not (Test-Path $script:IndexFile)) {
        @{} | ConvertTo-Json | Set-Content $script:IndexFile -Encoding UTF8
    }
}

function Initialize-BucketInIndex {
    <#
    .SYNOPSIS
        Initializes a bucket entry in the index if it doesn't exist
    #>
    param(
        [hashtable]$Index,
        [string]$BucketName
    )
    
    if (-not $Index.ContainsKey($BucketName)) {
        $Index[$BucketName] = @{
            hash = $null
            packages = @{}
        }
    }
}

function Get-BucketList {
    <#
    .SYNOPSIS
        Gets list of all installed Scoop buckets
    #>
    if (-not (Test-Path $script:BucketsDir)) {
        Write-Host "Buckets directory not found: $script:BucketsDir" -ForegroundColor Red
        return @()
    }
    
    Get-ChildItem -Path $script:BucketsDir -Directory | Select-Object -ExpandProperty Name
}

function Get-GitCommitHash {
    <#
    .SYNOPSIS
        Gets the current git commit hash for a bucket
    #>
    param(
        [string]$BucketPath
    )
    
    if (-not (Test-Path (Join-Path $BucketPath ".git"))) {
        return $null
    }
    
    Push-Location $BucketPath
    try {
        $hash = git rev-parse HEAD 2>$null
        return $hash
    }
    catch {
        return $null
    }
    finally {
        Pop-Location
    }
}

function Remove-PackageFromIndex {
    <#
    .SYNOPSIS
        Removes a package from the grouped index
    #>
    param(
        [hashtable]$GroupedIndex,
        [string]$Name,
        [string]$Source
    )
    
    if ($GroupedIndex.ContainsKey($Source) -and $GroupedIndex[$Source].packages.ContainsKey($Name)) {
        $GroupedIndex[$Source].packages.Remove($Name)
    }
}

function Add-PackageToIndex {
    <#
    .SYNOPSIS
        Adds or updates a package in the grouped index
    #>
    param(
        [hashtable]$GroupedIndex,
        [string]$Name,
        [string]$Version,
        [string]$Source
    )
    
    Initialize-BucketInIndex -Index $GroupedIndex -BucketName $Source
    $GroupedIndex[$Source].packages[$Name] = $Version
}

function Update-BucketHash {
    <#
    .SYNOPSIS
        Updates the git hash for a bucket in the index
    #>
    param(
        [hashtable]$GroupedIndex,
        [string]$BucketName,
        [string]$Hash
    )
    
    Initialize-BucketInIndex -Index $GroupedIndex -BucketName $BucketName
    $GroupedIndex[$BucketName].hash = $Hash
}

function Read-ManifestFile {
    <#
    .SYNOPSIS
        Reads and parses a Scoop manifest file
    #>
    param(
        [string]$FilePath
    )
    
    try {
        $content = Get-Content $FilePath -Raw -ErrorAction Stop
        $manifest = $content | ConvertFrom-Json -ErrorAction Stop
        return $manifest
    }
    catch {
        Write-Verbose "Failed to parse manifest: $FilePath"
        return $null
    }
}

function Search-PackageIndex {
    <#
    .SYNOPSIS
        Searches the package index
        Supports searching by package name or "bucket/package" format
    #>
    param(
        [string]$Query
    )
    
    # Load and flatten index into cache if not already loaded
    if ($null -eq $script:PackageCache) {
        $groupedIndex = Read-PackageIndex
        $script:PackageCache = Get-FlattenedCache -GroupedIndex $groupedIndex
    }
    
    $queryLower = $Query.ToLowerInvariant()
    $results = @()
    
    # Search through all packages
    foreach ($key in $script:PackageCache.Keys) {
        $keyLower = $key.ToLowerInvariant()
        # Match against full "bucket/package" format
        if ($keyLower.Contains($queryLower)) {
            $parts = $key -split '/', 2
            $results += [PSCustomObject]@{
                name    = $parts[1]
                version = $script:PackageCache[$key]
                source  = $parts[0]
            }
        }
    }
    
    # Sort by name, then source
    return $results | Sort-Object name, source
}

function Scan-BucketForPackages {
    <#
    .SYNOPSIS
        Scans a specific bucket and returns hashtable of packages found
        Returns: @{ "packagename" = "version", ... }
    #>
    param(
        [string]$BucketName
    )
    
    $packages = @{}
    $bucketPath = Join-Path $script:BucketsDir $BucketName
    
    if (-not (Test-Path $bucketPath)) {
        return $packages
    }
    
    # Find manifest files
    $manifestPath = Join-Path $bucketPath "bucket"
    if (-not (Test-Path $manifestPath)) {
        $manifestPath = $bucketPath
    }
    
    $manifestFiles = Get-ChildItem -Path $manifestPath -Filter "*.json" -File -ErrorAction SilentlyContinue
    
    foreach ($file in $manifestFiles) {
        $packageName = $file.BaseName
        $manifest = Read-ManifestFile -FilePath $file.FullName
        
        if ($manifest -and $manifest.version) {
            $packages[$packageName] = $manifest.version
        }
    }
    
    return $packages
}

function Update-IncrementalIndex {
    <#
    .SYNOPSIS
        Updates package index incrementally by comparing with current bucket state
        Uses git hashes embedded in index to detect changed buckets
        Also detects NEW buckets added after index creation
        Adds new packages, removes deleted packages, updates changed versions
    #>
    
    Write-Verbose "Performing incremental index update..."
    
    $buckets = Get-BucketList
    $groupedIndex = Read-PackageIndex
    $changedBuckets = @()
    $bucketHashes = @{}
    $bucketPaths = @{}
    
    # Cache bucket paths
    foreach ($bucket in $buckets) {
        $bucketPaths[$bucket] = Join-Path $script:BucketsDir $bucket
    }
    
    # Check git status for each bucket and detect new/changed buckets
    foreach ($bucket in $buckets) {
        $currentHash = Get-GitCommitHash -BucketPath $bucketPaths[$bucket]
        $bucketHashes[$bucket] = $currentHash
        
        # Check if bucket is new or changed
        $oldHash = if ($groupedIndex.ContainsKey($bucket)) { $groupedIndex[$bucket].hash } else { $null }
        if ($oldHash -ne $currentHash) {
            $changedBuckets += $bucket
        }
    }
    
    # If no buckets changed, nothing to do
    if ($changedBuckets.Count -eq 0) {
        return @{ added = 0; removed = 0; updated = 0 }
    }
    
    $added = 0
    $remoted = 0
    
    # Process each changed bucket
    foreach ($bucket in $changedBuckets) {
        $bucketPath = Join-Path $script:BucketsDir $bucket
        $currentHash = $bucketHashes[$bucket]
        $currentPackages = Scan-BucketForPackages -BucketName $bucket
        
        # Get old packages for this bucket
        $oldPackages = if ($groupedIndex.ContainsKey($bucket) -and $groupedIndex[$bucket].packages) {
            $groupedIndex[$bucket].packages
        } else {
            @{}
        }
        
        # Find packages to add or update
        foreach ($pkgName in $currentPackages.Keys) {
            $newVersion = $currentPackages[$pkgName]
            
            if ($oldPackages.ContainsKey($pkgName)) {
                # Package exists, check if version changed
                if ($oldPackages[$pkgName] -ne $newVersion) {
                    Add-PackageToIndex -GroupedIndex $groupedIndex -Name $pkgName -Version $newVersion -Source $bucket
                    $updated++
                }
            }
            else {
                # New package
                Add-PackageToIndex -GroupedIndex $groupedIndex -Name $pkgName -Version $newVersion -Source $bucket
                $added++
            }
        }
        
        # Find packages to remove (in index but not in current scan)
        foreach ($pkgName in $oldPackages.Keys) {
            if (-not $currentPackages.ContainsKey($pkgName)) {
                Remove-PackageFromIndex -GroupedIndex $groupedIndex -Name $pkgName -Source $bucket
                $removed++
            }
        }
        
        # Update bucket hash
        Update-BucketHash -GroupedIndex $groupedIndex -BucketName $bucket -Hash $currentHash
    }
    
    # Write updated index to file
    Write-PackageIndex -GroupedIndex $groupedIndex
    
    # Update flattened cache
    $script:PackageCache = Get-FlattenedCache -GroupedIndex $groupedIndex
    
    return @{ added = $added; removed = $removed; updated = $updated }
}

#endregion

#region Main Execution

if (-not $PackageName) {
    Write-Host "Usage: .\Scoop-Search.ps1 <package_name>" -ForegroundColor Yellow
    Write-Host "`nExamples:"
    Write-Host "  .\Scoop-Search.ps1 python"
    Write-Host "  .\Scoop-Search.ps1 stremio" -ForegroundColor Gray
    exit 0
}

# Initialize
if (-not (Test-Path $script:IndexFile)) {
    Initialize-Database
}

# Search index
$results = Search-PackageIndex -Query $PackageName

# If no results, update and search again
if ($results.Count -eq 0) {
    Write-Host "Updating package index..." -ForegroundColor Yellow
    scoop update 2>$null
    Update-IncrementalIndex | Out-Null
    $results = Search-PackageIndex -Query $PackageName
}

# Display results
if ($results.Count -eq 0) {
    Write-Host "No packages found matching '$PackageName'" -ForegroundColor Yellow
} else {
    $results | Format-Table -Property Name, Version, Source -AutoSize
}

#endregion
