#Copyright (c) 2025, Douglass Davis
#All rights reserved.
#BSD3 License

#This source code is licensed under the BSD-style license found in the
#LICENSE file in the root directory of this source tree. 

#THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
#INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.

# --- CONFIG ---
$musicRoot = "<directory>"
$outputCsv = "<csv output file>"
$diagnosticLog = "<diagnostic log file>"
$fpcalc = "<path to fpcalk>"
$acoustIdKey = "<acoustid Key>"

# --- CHECK REQUIREMENTS ---
if (!(Test-Path $fpcalc)) {
    throw "fpcalc not found at $fpcalc"
}

# Verify kid3-cli exists with better error handling
$kid3 = "kid3-cli"
try {
    $null = & $kid3 --help 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kid3-cli returned error code"
    }
} catch {
    Write-Error "kid3-cli not found or not working properly."
    Write-Error "Make sure kid3-cli is installed and in your PATH."
    exit 1
}

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

# --- MUSICBRAINZ FALLBACK FUNCTION ---
function Get-YearFromMusicBrainz {
    param(
        [string]$artist,
        [string]$title
    )
    
    Write-Host "  -> Trying MusicBrainz fallback search..." -ForegroundColor Cyan
    "Attempting MusicBrainz fallback search" | Out-File $diagnosticLog -Append
    
    # Build search query
    $query = "$title artist:$artist"
    $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
    $url = "https://musicbrainz.org/ws/2/recording/?query=$encodedQuery&fmt=json&limit=5"
    
    "MusicBrainz URL: $url" | Out-File $diagnosticLog -Append
    
    try {
        # MusicBrainz requires a User-Agent header
        $headers = @{
            'User-Agent' = 'MusicYearFinder/1.0 (music-library-tool@example.com)'
        }
        
        $response = Invoke-RestMethod -Uri $url -Headers $headers -ErrorAction Stop
        
        # Log response
        "MusicBrainz Response:" | Out-File $diagnosticLog -Append
        $response | ConvertTo-Json -Depth 5 | Out-File $diagnosticLog -Append
        
        $years = @()
        
        # Extract years from all recordings
        if ($response.recordings) {
            Write-Host "  -> Found $($response.recordings.count) recordings" -ForegroundColor Gray
            
            foreach ($recording in $response.recordings) {
                if ($recording.releases) {
                    foreach ($release in $recording.releases) {
                        if ($release.date) {
                            # Extract year from date (format: YYYY-MM-DD or just YYYY)
                            if ($release.date -match '^(\d{4})') {
                                $year = [int]$matches[1]
                                $years += $year
                                "  Found year in MusicBrainz release: $year from date: $($release.date)" | Out-File $diagnosticLog -Append
                            }
                        }
                    }
                }
            }
        }
        
        if ($years.Count -gt 0) {
            # Return earliest year
            $earliestYear = ($years | Measure-Object -Minimum).Minimum
            Write-Host "  -> MusicBrainz found earliest year: $earliestYear (from $($years.Count) releases)" -ForegroundColor Green
            "MusicBrainz earliest year: $earliestYear" | Out-File $diagnosticLog -Append
            
            # Rate limit: MusicBrainz allows 1 request per second
            Start-Sleep -Seconds 1
            
            return $earliestYear
        } else {
            Write-Host "  -> MusicBrainz found no release dates" -ForegroundColor Yellow
            "MusicBrainz found no release dates" | Out-File $diagnosticLog -Append
        }
        
        # Rate limit even on failure
        Start-Sleep -Seconds 1
        
    } catch {
        Write-Warning "  -> MusicBrainz search failed: $_"
        "MusicBrainz search error: $_" | Out-File $diagnosticLog -Append
        Start-Sleep -Seconds 1
    }
    
    return $null
}

# Clear/create diagnostic log
"AcoustID API Diagnostics Log - $(Get-Date)" | Out-File $diagnosticLog
"=" * 80 | Out-File $diagnosticLog -Append

$results = @()
$processedCount = 0

# --- SCAN FILES ---
Write-Host "Scanning for music files in: $musicRoot"
$files = Get-ChildItem -Path $musicRoot -Recurse -Include *.mp3, *.m4a -File

Write-Host "Found $($files.Count) files to check"

foreach ($fileItem in $files) {
    $file = $fileItem.FullName
    $processedCount++
    
    Write-Host "`n[$processedCount/$($files.Count)] Checking: $($fileItem.Name)"
    "`n[$processedCount] FILE: $file" | Out-File $diagnosticLog -Append

    # Read existing year with null check
    $yearOutput = & $kid3 -c "get TDRC" "$file" 2>&1
    $year = if ($yearOutput) { $yearOutput.ToString().Trim() } else { "" }

    if ($year -and $year -ne "") {
        Write-Host "  -> Already has year: $year (skipping)"
        continue
    }

    Write-Host "  -> Missing year, looking up..."

    # Read artist/title early (needed for fallback)
    $artistOutput = & $kid3 -c "get artist" "$file" 2>&1
    $artist = if ($artistOutput) { $artistOutput.ToString().Trim() } else { "" }
    
    $titleOutput = & $kid3 -c "get title" "$file" 2>&1
    $title = if ($titleOutput) { $titleOutput.ToString().Trim() } else { "" }

    Write-Host "  -> Artist: $artist"
    Write-Host "  -> Title: $title"

    # Fingerprint file
    try {
        $fpOutput = & $fpcalc "$file" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  -> fpcalc failed for this file"
            "ERROR: fpcalc failed with exit code $LASTEXITCODE" | Out-File $diagnosticLog -Append
            
            # Try MusicBrainz fallback if we have artist and title
            if ($artist -and $title -and $artist -ne "" -and $title -ne "") {
                $fallbackYear = Get-YearFromMusicBrainz -artist $artist -title $title
                
                if ($fallbackYear) {
                    $lookupYear = $fallbackYear.ToString()
                    $status = "FallbackFound"
                    
                    # Try to update the file
                    try {
                        $updateOutput = & $kid3 -c "set TDRC `"$lookupYear`"" "$file" 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $status = "UpdatedFallback"
                            Write-Host "  -> Successfully updated from fallback!" -ForegroundColor Green
                            "Successfully updated TDRC from fallback" | Out-File $diagnosticLog -Append
                        }
                    } catch {
                        Write-Warning "  -> Found year but failed to update: $_"
                    }
                }
            }
            
            # Create result entry and continue to next file
            $song = "$title $artist"
            $search_enc = [System.Web.HttpUtility]::UrlEncode($song)
            $search_url = "https://www.google.com/search?q=$search_enc"
            
            $results += [pscustomobject]@{
                Path         = $file
                Artist       = $artist
                Title        = $title
                LookupYear   = if ($lookupYear) { $lookupYear } else { "" }
                Status       = if ($status) { $status } else { "FpcalcFailed" }
                GoogleSearch = $search_url
            }
            
            continue
        }
    } catch {
        Write-Warning "  -> Error running fpcalc: $_"
        "ERROR: fpcalc exception: $_" | Out-File $diagnosticLog -Append
        continue
    }

    # Parse fpcalc output safely
    "fpcalc output:" | Out-File $diagnosticLog -Append
    $fpOutput | Out-File $diagnosticLog -Append
    
    $durationLine = $fpOutput | Where-Object { $_ -match "DURATION=" } | Select-Object -First 1
    $fingerprintLine = $fpOutput | Where-Object { $_ -match "FINGERPRINT=" } | Select-Object -First 1

    if (!$durationLine -or !$fingerprintLine) {
        Write-Warning "  -> Could not parse fpcalc output"
        "ERROR: Could not parse duration or fingerprint" | Out-File $diagnosticLog -Append
        continue
    }

    $duration = $durationLine.ToString().Split("=")[1].Trim()
    $fingerprint = $fingerprintLine.ToString().Split("=")[1].Trim()

    Write-Host "  -> Duration: $duration seconds"
    Write-Host "  -> Fingerprint length: $($fingerprint.Length) chars"
    
    "Duration: $duration" | Out-File $diagnosticLog -Append
    "Fingerprint: $fingerprint" | Out-File $diagnosticLog -Append

    # Query AcoustID API
    $url = "https://api.acoustid.org/v2/lookup?client=$acoustIdKey&meta=releases&duration=$duration&fingerprint=$fingerprint"
    
    "API URL: $url" | Out-File $diagnosticLog -Append
    Write-Host "  -> Querying AcoustID API..."

    try {
        $response = Invoke-RestMethod -Uri $url -ErrorAction Stop
        
        # Log full response
        "API Response:" | Out-File $diagnosticLog -Append
        $response | ConvertTo-Json -Depth 10 | Out-File $diagnosticLog -Append
        
    } catch {
        Write-Warning "  -> API lookup failed: $_"
        "ERROR: API request failed: $_" | Out-File $diagnosticLog -Append
        
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            "API Error Response Body: $responseBody" | Out-File $diagnosticLog -Append
            Write-Host "  -> API Error: $responseBody" -ForegroundColor Red
        }
        continue
    }

    $lookupYear = ""
    $status = "NoMatch"

    # Detailed response analysis
    Write-Host "  -> Response status: $($response.status)"
    "Response status: $($response.status)" | Out-File $diagnosticLog -Append
    
    if ($response.status -eq "ok") {
        Write-Host "  -> Results count: $($response.results.count)"
        "Results count: $($response.results.count)" | Out-File $diagnosticLog -Append
        
        if ($response.results.count -gt 0) {
            # Find the result with the highest score
            $bestResult = $response.results | Sort-Object -Property score -Descending | Select-Object -First 1
            
            Write-Host "  -> Best result score: $($bestResult.score)"
            "Best result score: $($bestResult.score)" | Out-File $diagnosticLog -Append
            "Best result ID: $($bestResult.id)" | Out-File $diagnosticLog -Append
            
            if ($bestResult.releases) {
                Write-Host "  -> Releases count: $($bestResult.releases.count)"
                "Releases count: $($bestResult.releases.count)" | Out-File $diagnosticLog -Append
                
                # Collect all years from all releases
                $allYears = @()
                
                foreach ($release in $bestResult.releases) {
                    if ($release.releaseevents) {
                        foreach ($event in $release.releaseevents) {
                            if ($event.date -and $event.date.year) {
                                $allYears += $event.date.year
                                "  Found year in release event: $($event.date.year)" | Out-File $diagnosticLog -Append
                            }
                        }
                    }
                    # Also check the release date directly (not in releaseevents)
                    if ($release.date -and $release.date.year) {
                        $allYears += $release.date.year
                        "  Found year in release date: $($release.date.year)" | Out-File $diagnosticLog -Append
                    }
                }
                
                if ($allYears.Count -gt 0) {
                    # Find the earliest year
                    $earliestYear = ($allYears | Measure-Object -Minimum).Minimum
                    $lookupYear = $earliestYear.ToString()
                    
                    # Update the file with kid3
                    Write-Host "  -> Updating file with year: $lookupYear" -ForegroundColor Cyan
                    "Attempting to update TDRC tag with year: $lookupYear" | Out-File $diagnosticLog -Append
                    
                    try {
                        $updateOutput = & $kid3 -c "set TDRC `"$lookupYear`"" "$file" 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $status = "Updated"
                            Write-Host "  -> Successfully updated file!" -ForegroundColor Green
                            "Successfully updated TDRC tag" | Out-File $diagnosticLog -Append
                        } else {
                            $status = "UpdateFailed"
                            Write-Warning "  -> Failed to update file (exit code: $LASTEXITCODE)"
                            "Failed to update TDRC tag: $updateOutput" | Out-File $diagnosticLog -Append
                        }
                    } catch {
                        $status = "UpdateFailed"
                        Write-Warning "  -> Exception updating file: $_"
                        "Exception updating TDRC tag: $_" | Out-File $diagnosticLog -Append
                    }
                    
                    "MATCHED YEAR: $lookupYear (earliest from $($allYears.Count) dates)" | Out-File $diagnosticLog -Append
                } else {
                    Write-Host "  -> No release dates found in any releases" -ForegroundColor Yellow
                    "No release dates found" | Out-File $diagnosticLog -Append
                }
            } else {
                Write-Host "  -> No releases in best result" -ForegroundColor Yellow
                "No releases found" | Out-File $diagnosticLog -Append
            }
        } else {
            Write-Host "  -> No results returned from API" -ForegroundColor Yellow
            "No results from API (fingerprint not recognized)" | Out-File $diagnosticLog -Append
        }
    } else {
        Write-Host "  -> API returned error status: $($response.status)" -ForegroundColor Red
        if ($response.error) {
            Write-Host "  -> Error message: $($response.error.message)" -ForegroundColor Red
            "API Error: $($response.error.message)" | Out-File $diagnosticLog -Append
        }
    }

    # Try MusicBrainz fallback if AcoustID failed AND we have both artist and title
    if ($status -eq "NoMatch" -and $artist -and $title -and $artist -ne "" -and $title -ne "") {
        Write-Host "  -> AcoustID found no match, trying MusicBrainz..." -ForegroundColor Yellow
        
        $fallbackYear = Get-YearFromMusicBrainz -artist $artist -title $title
        
        if ($fallbackYear) {
            $lookupYear = $fallbackYear.ToString()
            $status = "FallbackFound"
            
            # Try to update the file
            Write-Host "  -> Updating file with fallback year: $lookupYear" -ForegroundColor Cyan
            "Attempting to update TDRC tag with fallback year: $lookupYear" | Out-File $diagnosticLog -Append
            
            try {
                $updateOutput = & $kid3 -c "set TDRC `"$lookupYear`"" "$file" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $status = "UpdatedFallback"
                    Write-Host "  -> Successfully updated from fallback!" -ForegroundColor Green
                    "Successfully updated TDRC from fallback" | Out-File $diagnosticLog -Append
                } else {
                    Write-Warning "  -> Failed to update file (exit code: $LASTEXITCODE)"
                    "Failed to update TDRC from fallback: $updateOutput" | Out-File $diagnosticLog -Append
                }
            } catch {
                Write-Warning "  -> Exception updating file: $_"
                "Exception updating TDRC from fallback: $_" | Out-File $diagnosticLog -Append
            }
        }
    }

    if ($status -eq "NoMatch") {
        Write-Host "  -> No match found in any database" -ForegroundColor Yellow
    }

    $song = "$title $artist"
    $search_enc = [System.Web.HttpUtility]::UrlEncode($song)
    $search_url = "https://www.google.com/search?q=$search_enc"
    
    $results += [pscustomobject]@{
        Path         = $file
        Artist       = $artist
        Title        = $title
        LookupYear   = $lookupYear
        Status       = $status
        GoogleSearch = $search_url
    }

    Start-Sleep -Milliseconds 500
}

# Export results
if ($results.Count -gt 0) {
    $results | Export-Csv -Path $outputCsv -NoTypeInformation
    Write-Host "`nDONE! Processed $($results.Count) files with missing years." -ForegroundColor Green
    Write-Host "CSV written to: $outputCsv" -ForegroundColor Green
    Write-Host "Diagnostic log written to: $diagnosticLog" -ForegroundColor Cyan
    
    $updatedCount = ($results | Where-Object { $_.Status -eq "Updated" }).Count
    $updatedFallbackCount = ($results | Where-Object { $_.Status -eq "UpdatedFallback" }).Count
    $noMatchCount = ($results | Where-Object { $_.Status -eq "NoMatch" }).Count
    $failedCount = ($results | Where-Object { $_.Status -eq "UpdateFailed" }).Count
    $fallbackFoundCount = ($results | Where-Object { $_.Status -eq "FallbackFound" }).Count
    
    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host "  Updated (AcoustID): $updatedCount" -ForegroundColor Green
    Write-Host "  Updated (MusicBrainz): $updatedFallbackCount" -ForegroundColor Green
    if ($fallbackFoundCount -gt 0) {
        Write-Host "  Fallback Found (not updated): $fallbackFoundCount" -ForegroundColor Yellow
    }
    Write-Host "  No Match: $noMatchCount" -ForegroundColor Yellow
    if ($failedCount -gt 0) {
        Write-Host "  Update Failed: $failedCount" -ForegroundColor Red
    }
} else {
    Write-Host "`nNo files with missing years found." -ForegroundColor Yellow
}
