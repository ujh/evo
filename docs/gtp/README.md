# GTP version 2 specification

A copy of the Go Text Protocol specification, version 2, which the arena's
bot controller (`engine/bot.c`) and evo's own GTP engine speak, kept here to
read and search offline. It is titled "draft 2", but it is the accepted
version 2 specification.

- Source: <https://www.lysator.liu.se/~gunnar/gtp/gtp2-spec-draft2/gtp2-spec.html>,
  by Gunnar Farnebäck, October 2002. Fetched on 28 September 2026.
- `gtp2-spec.html`, `gtp2-spec.css`, and `img1.gif` to `img9.gif` are the
  published files, unmodified.
- `gtp2-spec.txt` is a plain-text rendering for grep, not part of the
  original: each formula image was replaced by its `ALT` text (with `$`
  dropped, `\vert` as `|`, `^{31}` as `^31`), and the result converted with
  macOS `textutil -convert txt -inputencoding iso-8859-1`. The HTML is the
  authoritative copy.

## Licence

These files are not under the repository's MIT licence. The specification
says: "Permission is granted to make and distribute verbatim or modified
copies of this specification provided that the terms of the GNU Free
Documentation License (section 10) are respected." Section 10 of the
specification holds that licence; `fdl-1.1.txt` is the GNU Free
Documentation License, version 1.1, from
<https://www.gnu.org/licenses/old-licenses/fdl-1.1.txt>.
