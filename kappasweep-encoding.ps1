$utf8 = [Text.UTF8Encoding]::new($false)

try {
    [Console]::OutputEncoding = $utf8
}
catch {
}

try {
    $global:OutputEncoding = $utf8
}
catch {
}
