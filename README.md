# liberime-regexp

`liberime-regexp` lets Emacs search and jump with lower-case Rime codes. For
example, searching for `ni` can match the Rime candidate `你`. It works with
built-in `isearch` and Avy, and integrates with Orderless and Evil search when
they are available.

Requirements: Emacs 27.1 or newer, [Avy](https://github.com/abo-abo/avy) 0.5.0
or newer, and [liberime](https://github.com/emacs-rime/liberime) 0.0.7 or newer.

## Installation

With `straight.el` and `use-package`:

```elisp
(use-package liberime-regexp
  :straight (liberime-regexp
             :type git
             :host github
             :repo "roife/liberime-regexp")
  :hook (liberime-after-start . liberime-regexp-enable))
```

## Avy

Enable Rime expansion for Avy's character commands:

```elisp
(liberime-regexp-avy-mode 1)
```

This remaps `avy-goto-char`, `avy-goto-char-in-line`, `avy-goto-char-2`, and
`avy-goto-char-timer`. The timer command accepts a complete Rime code, so
typing `ni` can jump to `你` or another visible Rime candidate.

## Options

Customize these variables with `M-x customize-group RET liberime-regexp` or
set them in your Emacs configuration.

| Variable | Default | Description |
| --- | ---: | --- |
| `liberime-regexp-max-code-length` | `0` | Maximum code length to expand. `0` means no limit. |
| `liberime-regexp-candidate-limit` | `100` | Maximum candidates examined for one code. `nil` or a non-positive value means no limit. |
| `liberime-regexp-cache-size` | `256` | Maximum number of cached queries. A non-positive value disables caching. |
| `liberime-regexp-omit-code-separators` | `t` | Allow whitespace between adjacent Rime codes to match nothing. |

## Thanks

Thanks to [`rime-regexp.el`](https://github.com/colawithsauce/rime-regexp.el)
for the inspiration.
