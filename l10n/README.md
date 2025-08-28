# Multi-language support

The plugin uses the same language translation logic as KOReader.

## How it Works

The localization process uses standard `gettext` tools (`.pot` template file and `.po` language files).

-   `templates/koreader.pot`: The template file containing all translatable strings from the source code.
-   `<LANG_CODE>/koreader.po`: The translation file for a specific language.

The `Makefile` in this directory automates most of the translation process.

## Updating Translations

When the source code changes, new strings might be added or existing ones modified. To update all language files:

1.  **Generate Template**: Update the `.pot` template file from the source code.
    ```bash
    make template
    ```
2.  **Update PO Files**: Merge the new template into all existing `.po` files. New strings will be added and marked as untranslated.
    ```bash
    make update
    ```
3.  **Translate Untranslated Strings**:
    -   **With AI**: The `Makefile` is configured to use an AI translation script. You need to have an `API_KEY` environment variable set.
        ```bash
        # This will find all untranslated strings, translate them, and merge them back.
        make ai-translate
        ```
    -   **Manually**:
        1.  Find untranslated strings:
            ```bash
            make extract-untranslated
            ```
            This creates an `untranslated.po` file in each language directory.
        2.  Edit the `koreader.po` file in the respective language directory and provide the translations for the new strings (they will have an empty `msgstr ""`).

## Adding a New Language

### Using AI Translation (Recommended)

1.  **Add Language to Script**: Open `AI_TRANSLATE.sh` and add your language code and name to the `LANG_MAP` associative array.
2.  **Run AI Translation**: Run the following command, replacing `<LANG_CODE>` with your language's code (e.g., `fr`). You will need an `API_KEY` for your chosen AI provider.
    ```bash
    make ai-translate L10N_LANG=<LANG_CODE>
    ```
    This will:
    - Create the directory for your language.
    - Create a `koreader.po` file and translate all strings from the template using the AI.

### Manually

1.  **Create Directory**: Create a directory for your language code (e.g., `mkdir fr`).
2.  **Create PO File**: Copy the template to your new language directory.
    ```bash
    cp templates/koreader.pot fr/koreader.po
    ```
3.  **Translate**: Open `fr/koreader.po` and translate all the `msgstr` fields.
    - Remember to update the header information at the top of the file.

## Language Abbreviation Table

```lua
    language_names = {
        en = "English",
        en_GB = "English (United Kingdom)",
        ca = "Catalá",
        cs = "Čeština",
        da = "Dansk",
        de = "Deutsch",
        eo = "Esperanto",
        es = "Español",
        eu = "Euskara",
        fi = "Suomi",
        fr = "Français",
        gl = "Galego",
        it_IT = "Italiano",
        he = "עִבְרִית",
        hr = "Hrvatski",
        hu = "Magyar",
        lt_LT = "Lietuvių",
        lv = "Latviešu",
        nl_NL = "Nederlands",
        nb_NO = "Norsk bokmål",
        pl = "Polski",
        pl_PL = "Polski2",
        pt_PT = "Português",
        pt_BR = "Português do Brasil",
        ro = "Română",
        ro_MD = "Română (Moldova)",
        sk = "Slovenčina",
        sv = "Svenska",
        th = "ภาษาไทย",
        vi = "Tiếng Việt",
        tr = "Türkçe",
        vi_VN = "Viet Nam",
        ar = "عربى",
        bg_BG = "български",
        bn = "বাংলা",
        el = "Ελληνικά",
        fa = "فارسی",
        hi = "हिन्दी",
        ja = "日本語",
        ka = "ქართული",
        kk = "Қазақ",
        ko_KR = "한국어",
        ru = "Русский",
        sr = "Српски",
        uk = "Українська",
        zh = "中文",
        zh_CN = "简体中文",
        zh_TW = "中文（台灣)",
    }
```
