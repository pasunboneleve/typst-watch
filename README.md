# typst-watch

`typst-watch` is an Emacs minor mode for Typst projects.  It starts one
buffer-local `typst watch` process per Typst file and stops that process when
the buffer dies.

It also provides compile and preview commands that open the generated PDF in a
viewer.  By default it tries `zathura` first and falls back to `evince`.

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

## Commands

- `M-x typst-watch-mode`: start or stop `typst watch` for the current buffer.
- `M-x typst-watch-start`: start `typst watch`.
- `M-x typst-watch-stop`: stop the buffer-local watch process.
- `M-x typst-watch-compile`: run `typst compile` and open the PDF.
- `M-x typst-watch-preview`: open the current PDF output.
- `M-x typst-watch-compile-and-preview`: compile and open the PDF.

`typst-watch-mode` binds `C-c ! w` to toggle the watcher, `C-c ! c` to
compile, and `C-c ! p` to preview.

When `typst-watch-auto-mode` is enabled, `typst-ts-compile`,
`typst-ts-preview`, and `typst-ts-compile-and-preview` also open the PDF viewer
after they run, when those commands are defined.

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
