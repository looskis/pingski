enum DocsPage {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Pingski API</title>
      <style>
        body { margin: 0; font-family: -apple-system, system-ui, sans-serif; }
        #fallback { padding: 2rem; max-width: 60rem; margin: 0 auto; }
        code { background: #f2f2f2; padding: 0.1rem 0.3rem; border-radius: 4px; }
      </style>
    </head>
    <body>
      <div id="app"></div>
      <noscript><div id="fallback">The interactive reference needs JavaScript. The raw specification is at <code>/openapi.json</code>.</div></noscript>
      <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
      <script>
        if (window.Scalar) {
          Scalar.createApiReference('#app', { url: '/openapi.json', hideDownloadButton: false });
        } else {
          document.getElementById('app').innerHTML = '<div id="fallback"><h1>Pingski API</h1><p>Could not load the documentation UI (no internet?). The OpenAPI document is served at <code>/openapi.json</code>.</p></div>';
        }
      </script>
    </body>
    </html>
    """
}
