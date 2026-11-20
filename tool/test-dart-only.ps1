# Runs Dart/widget regression with an injected-reader native hook mapping.
# It never compiles TagLib. Native fixture tests remain for GitHub CI.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$TestArguments)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pubspec = Join-Path $project 'pubspec.yaml'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$original = [IO.File]::ReadAllText($pubspec, $utf8)
$marker = "`nhooks:`n  user_defines:`n    motif_taglib:`n      test-only-injected-reader: true`n"
if ($original -match '(?m)^hooks:') { throw 'Existing hooks configuration requires a targeted update.' }
Push-Location -LiteralPath $project
try {
    [IO.File]::WriteAllText($pubspec, $original + $marker, $utf8)
    & flutter test --no-pub --exclude-tags taglib-native --reporter expanded @TestArguments
    $testExit = $LASTEXITCODE
} finally {
    $current = [IO.File]::ReadAllText($pubspec, $utf8)
    if (!$current.EndsWith($marker, [StringComparison]::Ordinal)) {
        throw 'pubspec changed during tests; refusing a blind restore. Remove only the temporary test hook setting.'
    }
    [IO.File]::WriteAllText($pubspec, $current.Substring(0, $current.Length - $marker.Length), $utf8)
    Pop-Location
}
exit $testExit
