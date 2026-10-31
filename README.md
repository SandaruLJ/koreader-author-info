# Author Info for KOReader

Browse your library by author, with a photo and a short bio of each author.

- **Main menu → Authors** (above Favorites). For one-tap access, assign
  the **Authors** action to a gesture: Settings → Taps and gestures →
  Gesture manager → pick a gesture (e.g. tapping the top-left corner) →
  General → Authors.
- When the file browser shows covers, authors appear in the same grid, with
  each author's photo and name. In list or classic modes they appear in
  KOReader's standard list.
- **Tap an author** to see their books in the file browser's display style.
  The back arrow returns to the authors, and the ⓘ button shows **Author
  information**.
- **Hold an author** to view, find or replace (online), or remove their
  information or their image, each on its own. Buttons with nothing to act
  on are greyed out.
- **Author information** is laid out like KOReader's Book information:
  name, years, country, notable works, bio (tap to read), photo (tap
  to display), number of books in the library, and sources.
- The **☰ button** has:
  - **Sort by:** first name, last name, number of books or recently read,
    optionally reversed. For first name, a name written "Le Guin, Ursula K."
    is read as "Ursula K. Le Guin". For last name, the family name from Wikidata is
    used when the author's name contains it ("Liu Cixin" → Liu). Otherwise a
    name written "Le Guin, Ursula K." sorts by the part before the comma,
    and other names by the last word together with particles before it
    ("Walter de la Mare" → de la Mare), skipping suffixes like "Jr.".
  - **Filter:** by language or keywords, as in Collections: an author is
    shown when any of their books match, and only the matching books are
    listed when you tap them. By the author's country, once their
    information has been looked up. And by status:
    - **New** / **Reading:** authors with a book that is new or in progress.
    - **Read:** authors with at least one finished book.
    - **Unread:** authors with no finished book at all.
  - **Name position** (in the grid): below the photo, or on the photo in
    white on a black band across its bottom.
  - **Find missing:** look up the images, information, or both, of the
    authors shown that don't have them yet. The device is kept awake until
    the lookup finishes. Authors are looked up on Open Library one by one,
    then on Wikidata many at a time, then their bios. When a site asks to
    slow down, the lookup waits a minute and carries on (and stops if it
    asks again). Information that couldn't be looked up completely, because
    a site was busy or didn't answer, isn't saved, so the next Find missing
    tries those authors again.
  - **Clear:** delete the saved images, information, or both, of the
    authors shown (images include ones you added yourself). Use Find
    missing afterwards to look them up afresh. **Prune authors** deletes
    what is saved for authors who no longer have books in the library,
    as Cover browser's "Prune cache of removed books" does for books.

  These choices are remembered for next time, as KOReader does
  for Collections.

Books with several authors are listed under each of them.

## Where things come from

- Authors come from the Cover browser plugin's book information cache, so
  books show up once KOReader has shown their covers. Only books inside the
  home folder are included.
- Photos come from Open Library, or from Wikipedia when Open Library has
  none. A Wikipedia page is used only if its description says the person is
  a writer. Nothing is downloaded unless you ask.
- Photos are saved in `koreader/authorinfo/<Author Name>.jpg`. You can put
  your own JPEG or PNG there under the same name.
- Author information starts from the same Open Library match. Details
  (names, country, years, notable works) come from Wikidata, with
  labels in KOReader's language where available. The bio is the
  introduction of the author's Wikipedia page (everything before its first
  heading) in KOReader's language, else in English, else Open Library's
  bio. Its first paragraph is Wikipedia's tidied page summary, which leaves
  out the brackets after the name (dates, pronunciation). Older authors'
  historical countries are named by today's country (e.g. "United Kingdom
  of Great Britain and Ireland" → United Kingdom) where that is
  unambiguous.
- Information is saved beside the photo, in
  `koreader/authorinfo/<Author Name>.json`.

## Install

Copy this folder into KOReader's `plugins` folder as `authorinfo.koplugin`.
Requires the Cover browser plugin (bundled with KOReader).

## Credits and license

AGPL-3.0. The photo lookup is adapted from
[Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) (AGPL-3.0) by way
of ZenOS (GPL-3.0), which also supplied the HTTPS client.
