# EZProfileStore

EZProfileStore wraps ProfileStore with a fully typed server API for profile lifecycle, ordered schema migrations, mocks, historical rollbacks, transactions, and replicated mutations, plus a client API for reading a Fusion-backed local mirror. Paths into your data are generated from your template with `Path.tree`, and every read and write is checked against your data type.

Start with the README for installation and examples, then use the API pages for method-level details generated from the Moonwave comments in `src/`.
