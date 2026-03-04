param (
    [Parameter(Mandatory=$false)]
    [string]$Path = "*Designing an Automatic Smart Layout System*.md"
)

$resolved = Get-Item -Path $Path -ErrorAction SilentlyContinue | Select-Object -First 1

if (-Not $resolved) {
    Write-Error "File not found matching: $Path"
    exit 1
}

$Path = $resolved.FullName
Write-Host "Cleaning file: $Path"

# Read content as UTF-8
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8)

# Replace the Perplexity/GPT research citation format: \uE200...\uE201
# The regex \uE200[^\uE201]*\uE201 matches the start token, any character except end token, and the end token
$newContent = [regex]::Replace($content, "\uE200[^\uE201]*\uE201", "")

# Clean up possible trailing spaces before punctuation left after citation removal
# e.g., "word \uE200cite\uE201." -> "word ." -> "word."
$newContent = [regex]::Replace($newContent, " +(\.|,)", "$1")

# Write back to file as UTF-8 without BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path).ProviderPath, $newContent, $utf8NoBom)

Write-Host "Citations successfully cleaned from $Path"
