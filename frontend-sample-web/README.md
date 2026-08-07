# Web demo

A single-page demo of the map, list, dining menus, and the spot-a-food submission flow. It is plain HTML, CSS, and JavaScript with no build step.

## Running

The API base URL is the `API_BASE` constant inside `index.html`. Point it at your backend (for local development, `http://localhost:8000`), then serve the directory with any static file server:

```bash
python3 -m http.server 3000
```

and open http://localhost:3000. Opening `index.html` directly from disk also works for most browsers, but serving it avoids any local-file restrictions.

Themes live in `themes/` and are swapped by changing the stylesheet link in `index.html`.
