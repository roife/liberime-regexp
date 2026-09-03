# liberime-regexp

`liberime-regexp` lets Emacs search and jump with lower-case Rime codes. For
example, searching for `ni` can match the Rime candidate `你`. It works with
built-in `isearch` and Avy, and integrates with Orderless and Evil search when
they are available. It can also use the active Rime dictionary to segment
Chinese text and make word motion, killing, and marking respect those
boundaries.

Requirements: Emacs 27.1 or newer, [Avy](https://github.com/abo-abo/avy) 0.5.0
or newer, and [Liberime](https://github.com/emacs-rime/liberime) 0.0.7 or newer.

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

The `set_input` search optimization and Chinese segmentation use this
package's native module. Build it against the same librime version installed
on the system:

```sh
make RIME_PATH=/path/to/librime-source BOOST_INCLUDE=/path/to/boost/include
```

Set `RIME_INTERNAL_CXXFLAGS` when librime's internal dependency headers are in
non-standard locations. Alternatively, point `liberime-regexp-module-file` at
an already-built `liberime-regexp-core` module. Search still works without the
module by falling back to Liberime's ordinary candidate-search binding.

Missing modules are built automatically. Run `M-x liberime-regexp-build` to
build explicitly, or disable automatic builds before loading the package:

```elisp
(setq liberime-regexp-auto-build nil)
```

## Avy

Enable Rime expansion for Avy's character commands:

```elisp
(liberime-regexp-avy-mode 1)
```

This remaps `avy-goto-char`, `avy-goto-char-in-line`, `avy-goto-char-2`, and
`avy-goto-char-timer`. The timer command accepts a complete Rime code, so
typing `ni` can jump to `你` or another visible Rime candidate.

## Search optimization

Search expansion reuses an isolated Rime session, avoiding repeated session
creation and leaving the user's active composition untouched. If that session
cannot reproduce the active schema option state, the package falls back to its
original default-session query. The optional native module binds librime's
public `set_input` API directly; no Liberime source changes are required.

Predictive candidates whose genuine Rime type is `completion` are excluded.
The literal input remains in the regexp, so `exp` still matches `exp` but is
not expanded to English completions such as `explain`. Exact Chinese candidates
and shortest-prefix recursion are retained.

### Evaluation

With `luna_pinyin` and a 100-candidate limit:

| Implementation | Regexp construction | Generated regexp |
| --- | ---: | ---: |
| Native query + librime `set_input` | 2.2–3.0× faster on tested 20+ letter codes | byte-for-byte identical |

The optimization retains user dictionaries, automatic commits, schema output
filters, and the existing prefix/remainder recursion. Equivalence runs covered
519 Pinyin codes, 126 Cangjie codes, and 40 Stroke codes; non-completion
candidates retained their ordering and consumption structure. Completion
candidates are the only intentionally removed branches.

## Chinese word segmentation

`liberime-regexp-segment` returns zero-based word bounds, in the same shape as
EMT/ewt-rs:

```elisp
(liberime-regexp-segment "研究生命起源")
;; => ((0 . 2) (2 . 4) (4 . 6))

(liberime-regexp-split-string "研究生命起源")
;; => ("研究" "生命" "起源")
```

The exact result depends on the active Rime schema and its dictionaries. The
segmenter constructs one weighted word graph for each Han run and selects its
maximum-weight path. This excludes sentences synthesized by Rime from smaller
words. Single Han characters are used as a fallback.

Canonical spellings are read from librime's reverse dictionary and matched
directly against its binary tables. Keyboard spelling is bypassed, so full
Pinyin and double-Pinyin schemas backed by the same dictionary produce the same
word boundaries; shape-based schemas naturally use their own dictionary.
Output filters such as OpenCC are not run during this raw-table lookup, so a
filtered character variant must itself exist in the dictionary or it falls
back to single characters.

Enable Rime-aware word commands separately from search expansion:

```elisp
(liberime-regexp-segment-mode 1)
```

This remaps `forward-word`, `backward-word`, `kill-word`,
`backward-kill-word`, `mark-word`, and `word-at-point`. Ordinary non-Chinese
words continue to use Emacs's built-in word handling.

As in EMT, `liberime-regexp-word-at-point-or-forward` and
`liberime-regexp-word-at-point-or-backward` are interactive commands. At a
word boundary they choose the word on the named side and return its text.

## Options

Customize these variables with `M-x customize-group RET liberime-regexp` or
set them in your Emacs configuration.

| Variable | Default | Description |
| --- | ---: | --- |
| `liberime-regexp-max-code-length` | `0` | Maximum code length to expand. `0` means no limit. |
| `liberime-regexp-candidate-limit` | `100` | Maximum candidates examined for one code. `nil` or a non-positive value means no limit. |
| `liberime-regexp-cache-size` | `256` | Maximum number of cached queries. A non-positive value disables caching. |
| `liberime-regexp-omit-code-separators` | `t` | Allow whitespace between adjacent Rime codes to match nothing. |
| `liberime-regexp-segment-max-word-length` | `6` | Maximum Chinese word length considered during segmentation. |
| `liberime-regexp-segment-code-limit` | `64` | Maximum reverse-dictionary code combinations tried for a substring. |
| `liberime-regexp-segment-dictionary-namespace` | `translator` | Schema namespace used to create the librime Dictionary. |
| `liberime-regexp-segment-context-length` | `32` | Maximum Han context examined on each side of point for word operations. |
| `liberime-regexp-segment-single-character-weight` | `-12.0` | Fallback graph weight assigned to individual Han characters. |
| `liberime-regexp-module-file` | `nil` | Optional path to the liberime-regexp native module. |
| `liberime-regexp-auto-build` | `t` | Build the native module automatically when it is missing. |

## Thanks

Thanks to [`rime-regexp.el`](https://github.com/colawithsauce/rime-regexp.el)
for the search inspiration. The segmentation API and word commands are based
on ideas from [pyim](https://github.com/emacs-straight/pyim),
[EMT](https://github.com/roife/emt), and
[ewt-rs](https://github.com/Master-Hash/ewt-rs).
