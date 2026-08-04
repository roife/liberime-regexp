# liberime-regexp

Expand lower-case Rime codes in Emacs searches.

The package integrates with isearch, Orderless, and Evil search. With strict
matching enabled, candidates must consume the complete input code, so a query
such as `lcdsviyu` does not match the prefix candidate `老` from `劳动之余`.

## Installation

Using `use-package` and `straight.el`:

```elisp
(use-package liberime-regexp
  :straight (liberime-regexp
             :type git
             :host github
             :repo "roife/liberime-regexp")
  :config
  (liberime-regexp-mode 1))
```

The package requires [liberime](https://github.com/emacs-rime/liberime)
0.0.7 or newer.

## Options

`liberime-regexp-require-full-code-match` defaults to non-nil and filters out
prefix-only candidates. `liberime-regexp-candidate-limit` bounds candidate
enumeration, and `liberime-regexp-cache-size` controls the query cache.
