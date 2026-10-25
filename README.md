# Authors for KOReader

Browse your library by author, with a photo of each author.

- **Main menu → Authors** (next to History and Collections), or assign the
  **Authors** action to a gesture.
- When the file browser shows covers, authors appear in the same grid, with
  each author's photo and name. In list or classic modes they appear in
  KOReader's standard list.
- **Tap an author** to see their books in the file browser's display style.
  The back arrow returns to the authors.
- **Hold an author** to find, replace or remove their photo.
- The **☰ button** has:
  - **Sort by:** name, last name, number of books or recently read,
    optionally reversed. Last name is the part before a comma ("Le Guin,
    Ursula K."), otherwise the last word, so "Ursula K. Le Guin" sorts
    under G.
  - **Filter:** by language or keywords, as in Collections: an author is
    shown when any of their books match, and only the matching books are
    listed when you tap them. And by status:
    - **New** / **Reading:** authors with a book that is new or in progress.
    - **Read:** authors with at least one finished book.
    - **Unread:** authors with no finished book at all.
  - **Find missing author images** for the authors shown.

  The sort order and filters are remembered for next time, as KOReader does
  for Collections.

Books with several authors are listed under each of them.

## Where things come from

- Authors come from the Cover browser plugin's book information cache, so
  books show up once KOReader has shown their covers. Only books inside the
  home folder are included.
- Photos come from Open Library, or from Wikipedia when Open Library has
  none. A Wikipedia page is used only if its description says the person is
  a writer. Nothing is downloaded unless you ask.
- Photos are saved in `koreader/author-images/<Author Name>.jpg`. You can put
  your own JPEG or PNG there under the same name.

## Install

Copy this folder into KOReader's `plugins` folder as `authors.koplugin`.
Requires the Cover browser plugin (bundled with KOReader).

## Credits and license

AGPL-3.0. The photo lookup is adapted from
[Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) (AGPL-3.0) by way
of ZenOS (GPL-3.0), which also supplied the HTTPS client.
