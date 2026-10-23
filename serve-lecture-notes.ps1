[CmdletBinding()]
param(
  [int]$Port = 8765,
  [switch]$NoBrowser
)

$root = $PSScriptRoot.TrimEnd('\')
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")

$mimeTypes = @{
  '.html' = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'text/javascript; charset=utf-8'
  '.mjs'  = 'text/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.xml'  = 'application/xml; charset=utf-8'
  '.musicxml' = 'application/vnd.recordare.musicxml+xml'
  '.mxl'  = 'application/vnd.recordare.musicxml'
  '.mid'  = 'audio/midi'
  '.midi' = 'audio/midi'
  '.mp3'  = 'audio/mpeg'
  '.mp4'  = 'video/mp4'
  '.png'  = 'image/png'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.svg'  = 'image/svg+xml'
}

try {
  $listener.Start()
  $url = "http://localhost:$Port/lecture-notes_kimi_casio.html?v=20261023.13"
  Write-Output "Lecture Notes est disponible sur $url"
  Write-Output 'Laissez cette fenêtre ouverte pendant l’utilisation. Fermez-la avec Ctrl+C.'
  if (-not $NoBrowser) { Start-Process $url }

  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $relativePath = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart('/'))
      if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = 'lecture-notes_kimi_casio.html' }
      $filePath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath))
      if (-not $filePath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        $context.Response.StatusCode = 404
        $context.Response.Close()
        continue
      }
      $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
      $context.Response.ContentType = if ($mimeTypes.ContainsKey($extension)) { $mimeTypes[$extension] } else { 'application/octet-stream' }
      $context.Response.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
      $context.Response.Headers['Pragma'] = 'no-cache'
      $context.Response.Headers['Expires'] = '0'
      $stream = [System.IO.File]::OpenRead($filePath)
      try {
        $context.Response.ContentLength64 = $stream.Length
        $stream.CopyTo($context.Response.OutputStream)
      } finally {
        $stream.Dispose()
        $context.Response.Close()
      }
    } catch {
      try { $context.Response.StatusCode = 500; $context.Response.Close() } catch {}
    }
  }
} finally {
  if ($listener.IsListening) { $listener.Stop() }
  $listener.Close()
}
