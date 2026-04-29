[![CI](https://github.com/pasunboneleve/typst-watch/actions/workflows/test.yml/badge.svg)](https://github.com/pasunboneleve/typst-watch/actions/workflows/test.yml)
[![melpazoid](https://github.com/pasunboneleve/typst-watch/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/pasunboneleve/typst-watch/actions/workflows/melpazoid.yml)

# typst-watch

`typst-watch` is an Emacs minor mode for Typst projects.  It starts one
buffer-local `typst watch` process per Typst file and stops that process when
the buffer dies.

When a major-mode preview keybinding runs, `typst-watch` opens the generated
PDF in a viewer if it is not already open.  The original preview command is not
called, so `typst-ts-mode` browser previews are bypassed.  By default it tries
`zathura` first and falls back to `evince`.

## Requirements

- Emacs 27.1 or newer
- Typst on `PATH`
- A PDF viewer, usually `zathura` or `evince`
- `typst-ts-mode` or `typst-mode` for automatic activation

## Installation

Put `typst-watch.el` on your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/typst-watch")
(require 'typst-watch)
```

Enable automatic watching for Typst buffers:

```elisp
(typst-watch-auto-mode 1)
```

Or enable it per buffer:

```elisp
(add-hook 'typst-ts-mode-hook #'typst-watch-mode)
(add-hook 'typst-mode-hook #'typst-watch-mode)
```

## Behaviour

- `typst-watch-mode` starts `typst watch` when enabled and stops it when
  disabled.
- Closing the Typst buffer stops the buffer-local watch process.
- `typst-watch-auto-mode` enables `typst-watch-mode` in `typst-ts-mode` and
  `typst-mode` buffers.
- Major-mode preview commands listed in `typst-watch-preview-commands` are
  remapped to `typst-watch-preview`, which opens the PDF viewer when needed.
  Compile-only commands are left to the major mode.

## Configuration

Use a specific viewer:

```elisp
(setq typst-watch-pdf-viewer "zathura")
```

Change the fallback viewer:

```elisp
(setq typst-watch-fallback-pdf-viewer "evince")
```

Use a different Typst executable:

```elisp
(setq typst-watch-typst-command "/usr/local/bin/typst")
```

Disable automatic watcher startup while keeping preview integration:

```elisp
(setq typst-watch-start-on-enable nil)
```

Change the preview commands whose keybindings open the PDF viewer:

```elisp
(setq typst-watch-preview-commands
      '(typst-ts-preview typst-ts-mode-preview))
```

Change the output path rule:

```elisp
(setq typst-watch-output-file-function
      (lambda (source)
        (expand-file-name
         (concat (file-name-base source) ".pdf")
         (expand-file-name "build" (file-name-directory source)))))
```

## Development

Run the full local gate:

```sh
make all
```

Run only the tests:

```sh
make test
```
