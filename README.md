# liberime-regexp

Expand lower-case Rime codes in Emacs searches.

The package integrates with isearch, Orderless, and Evil search. Candidates
must collectively consume the complete input code, so `lcdsviyu` can match an
unlisted composition such as `唠懂只鱼` but does not match a prefix such as
`老`. Full-code candidates such as `劳动之余` are also retained.

## Installation

Using `use-package` and `straight.el`:

```elisp
(use-package liberime-regexp
  :straight (liberime-regexp
             :type git
             :host github
             :repo "roife/liberime-regexp")
  :hook (liberime-after-start . liberime-regexp-enable))
```

The package requires [liberime](https://github.com/emacs-rime/liberime)
0.0.7 or newer.

## Options

`liberime-regexp-candidate-limit` bounds candidate enumeration, and
`liberime-regexp-cache-size` controls the query cache.
