# tagfilter and svn repo doesn't work idk why

# Set error handling preferences
$ErrorActionPreference = 'Stop'

# Get the script's directory and move to parent
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Split-Path -Parent $scriptPath)

# Function to process repository information
function Process-Repository {
    param (
        [string]$RepoUrl,
        [string]$CurrentCommit,
        [string]$CurrentRev,
        [string]$CurrentHgRev,
        [string]$Branch,
        [string]$TagFilter,
        [string]$ScriptPath,
        [string]$VarPrefix
    )

    if ([string]::IsNullOrEmpty($RepoUrl)) {
        return $false
    }

    Write-Host "Processing repository: $RepoUrl"

    if (-not [string]::IsNullOrEmpty($CurrentRev)) {
        # SVN handling
        Write-Host "Checking svn rev for $RepoUrl..."
        try {
            # Create temp file for SVN config
            $svnConfig = Join-Path $env:TEMP "svn-config"
            @"
[auth]
store-auth-creds = no
[store-passwords]
enabled = no
[store-plaintext-passwords]
enabled = no
"@ | Set-Content $svnConfig

            # Use --non-interactive to skip authentication prompts
            $svnInfo = svn info --config-file $svnConfig --non-interactive --trust-server-cert --no-auth-cache $RepoUrl 2>$null
            if ($LASTEXITCODE -eq 0) {
                $newRev = ($svnInfo | Select-String "^Revision: ").ToString().Split(" ")[1].Trim()
                Write-Host "Got $newRev (current: $CurrentRev)"

                if ($newRev -ne $CurrentRev) {
                    Write-Host "Updating $ScriptPath"
                    $content = (Get-Content $ScriptPath) -replace "^$($VarPrefix)REV=.*", "$($VarPrefix)REV=`"$newRev`""
                    [System.IO.File]::WriteAllLines($ScriptPath, $content)
                }
            } else {
                Write-Host "Authentication required for SVN repository. Skipping..."
                return $true
            }

            # Cleanup
            if (Test-Path $svnConfig) {
                Remove-Item $svnConfig -Force
            }
        }
        catch {
            Write-Host "Failed to process SVN repository (possibly requires authentication). Skipping..."
            return $true
        }
    }
    elseif (-not [string]::IsNullOrEmpty($CurrentHgRev)) {
        # Mercurial handling
        Write-Host "Checking Mercurial rev for $RepoUrl..."
        try {
            $tempHgRepo = Join-Path $env:TEMP "tmphgrepo"
            if (Test-Path $tempHgRepo) {
                Remove-Item -Recurse -Force $tempHgRepo
            }
            
            New-Item -ItemType Directory -Path $tempHgRepo | Out-Null
            Push-Location $tempHgRepo
            
            & hg init
            $hgOutput = & hg in -f -n -l 1 --no-auth $RepoUrl 2>$null
            if ($LASTEXITCODE -eq 0) {
                $newHgRev = ($hgOutput | Select-String "changeset:").ToString().Split(":")[2].Trim()
                
                Write-Host "Got $newHgRev (current: $CurrentHgRev)"

                if ($newHgRev -ne $CurrentHgRev) {
                    Write-Host "Updating $ScriptPath"
                    $content = (Get-Content $ScriptPath) -replace "^$($VarPrefix)HGREV=.*", "$($VarPrefix)HGREV=`"$newHgRev`""
                    [System.IO.File]::WriteAllLines($ScriptPath, $content)
                }
            } else {
                Write-Host "Authentication required for Mercurial repository. Skipping..."
            }
            
            Pop-Location
            Remove-Item -Recurse -Force $tempHgRepo
        }
        catch {
            Write-Host "Failed to process Mercurial repository (possibly requires authentication). Skipping..."
            return $true
        }
    }
    elseif (-not [string]::IsNullOrEmpty($CurrentCommit)) {
        # Git handling
        try {
            if (-not [string]::IsNullOrEmpty($TagFilter)) {
                Write-Host "Using tag filter: $TagFilter"
                # Get all matching tags and their commit hashes
                $gitOutput = & git -c credential.helper= ls-remote --exit-code --tags --refs $RepoUrl "refs/tags/$TagFilter" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    # Sort tags using semantic versioning
                    $tags = $gitOutput | ForEach-Object {
                        $hash = $_.Split("`t")[0]
                        $tag = $_.Split("`t")[1].Replace("refs/tags/", "")
                        [PSCustomObject]@{
                            Hash = $hash
                            Tag = $tag
                            Version = [System.Version]($tag -replace '[^0-9.].*$')
                        }
                    } | Sort-Object Version

                    if ($tags.Count -gt 0) {
                        $latestTag = $tags[-1]
                        $newCommit = $latestTag.Hash
                        Write-Host "Found latest matching tag: $($latestTag.Tag)"
                    } else {
                        Write-Host "No matching tags found for filter: $TagFilter"
                        return $true
                    }
                } else {
                    Write-Host "Authentication required for Git repository. Skipping..."
                    return $true
                }
            }
            else {
                if ([string]::IsNullOrEmpty($Branch)) {
                    # Get default branch
                    $remoteInfo = & git -c credential.helper= remote show $RepoUrl 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $Branch = ($remoteInfo | Select-String "HEAD branch:").ToString().Split(":")[1].Trim()
                        Write-Host "Found default branch $Branch"
                    } else {
                        Write-Host "Authentication required for Git repository. Skipping..."
                        return $true
                    }
                }
                $gitOutput = & git -c credential.helper= ls-remote --exit-code --heads --refs $RepoUrl "refs/heads/$Branch" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $newCommit = $gitOutput.Split("`t")[0].Trim()
                } else {
                    Write-Host "Authentication required for Git repository. Skipping..."
                    return $true
                }
            }

            Write-Host "Got $newCommit (current: $CurrentCommit)"

            if ($newCommit -ne $CurrentCommit) {
                Write-Host "Updating $ScriptPath"
                $content = (Get-Content $ScriptPath) -replace "^$($VarPrefix)COMMIT=.*", "$($VarPrefix)COMMIT=`"$newCommit`""
                [System.IO.File]::WriteAllLines($ScriptPath, $content)
            }
        }
        catch {
            Write-Host "Failed to process Git repository (possibly requires authentication). Skipping..."
            return $true
        }
    }
    else {
        # Unknown repository type
        Add-Content -Path $ScriptPath -Value "xxx_CHECKME_UNKNOWN_xxx"
        Write-Host "Unknown layout. Needs manual check."
        return $false
    }

    return $true
}

# Get all .sh files recursively
$scripts = Get-ChildItem -Recurse -Path "scripts.d" -Filter "*.sh"

foreach ($script in $scripts) {
    Write-Host "Processing $($script.FullName)"
    
    # Parse the shell script to extract variables
    $content = Get-Content $script.FullName
    $variables = @{}
    
    # Extract variables from the shell script using separate patterns for quoted and unquoted values
    foreach ($line in $content) {
        # Try to match variables with different formats
        if ($line -match '^(SCRIPT_[^=]+)="([^"]*)"') {
            # Double-quoted values
            $variables[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match "^(SCRIPT_[^=]+)='([^']*)'") {
            # Single-quoted values
            $variables[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match '^(SCRIPT_[^=]+)=(.*)') {
            # Unquoted values
            $variables[$Matches[1]] = $Matches[2].Trim()
        }
    }
    
    if ($variables['SCRIPT_SKIP']) {
        Write-Host "Script marked for skipping"
        continue
    }

    # Process each possible repository (1-9)
    $processed = $false
    for ($i = 1; $i -le 9; $i++) {
        $prefix = if ($i -eq 1) { "SCRIPT_" } else { "SCRIPT_$i" }
        
        $repo = $variables["${prefix}REPO"]
        $commit = $variables["${prefix}COMMIT"]
        $rev = $variables["${prefix}REV"]
        $hgrev = $variables["${prefix}HGREV"]
        $branch = $variables["${prefix}BRANCH"]
        $tagfilter = $variables["${prefix}TAGFILTER"]

        if ([string]::IsNullOrEmpty($repo)) {
            if ($i -eq 1) {
                # Mark scripts without repo source for manual check
                Add-Content -Path $script.FullName -Value "xxx_CHECKME_xxx"
                Write-Host "Needs manual check."
            }
            break
        }

        $processed = Process-Repository -RepoUrl $repo -CurrentCommit $commit -CurrentRev $rev `
            -CurrentHgRev $hgrev -Branch $branch -TagFilter $tagfilter `
            -ScriptPath $script.FullName -VarPrefix $prefix

        if (-not $processed) {
            break
        }
    }

    Write-Host ""
}