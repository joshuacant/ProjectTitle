#!/bin/bash
# translate_po.sh
# Purpose: Translate KOReader *.po files with ChatGPT

set -euo pipefail

# -------------------- Configuration --------------------
API_ENDPOINT=${API_ENDPOINT:-"https://api.openai.com/v1/chat/completions"}
API_MODEL=${API_MODEL:-"gpt-4o-mini"}
AUTH_HEADER="Authorization: Bearer ${API_KEY}"
PROMPT_TEMPLATE="Translate the following gettext .po file content to __YOUR_LANGUAGE__. \
Preserve the .po file structure, including msgid, msgstr, and other metadata. \
Ensure accurate and context-aware translation.  \
The commented text in the first lines are descriptive text for the file, update it as necessary. \
The message will display on UI, keep the translation clean and short and easy understanding. \
When a line contains \`@translators\` is present, consider that as context to the message. \
The first message is the metadata for the PO file. Make necessary updates to the metadata. \
Fill the \`Language\` field with the language name and the language code. \
Fill the \`Language-Team\` and \`Last-Translator\` fields with your identifical model name and versions. \
Do not modify other file structure. \
Only output the translated file content, do not use markdown format. \
"

declare -A LANG_MAP=(
  ["en"]="English"
  ["en_GB"]="English (United Kingdom)"
  ["ca"]="Catalá"
  ["cs"]="Čeština"
  ["da"]="Dansk"
  ["de"]="Deutsch"
  ["eo"]="Esperanto"
  ["es"]="Español"
  ["eu"]="Euskara"
  ["fi"]="Suomi"
  ["fr"]="Français"
  ["gl"]="Galego"
  ["it_IT"]="Italiano"
  ["he"]="עִבְרִית"
  ["hr"]="Hrvatski"
  ["hu"]="Magyar"
  ["lt_LT"]="Lietuvių"
  ["lv"]="Latviešu"
  ["nl_NL"]="Nederlands"
  ["nb_NO"]="Norsk bokmål"
  ["pl"]="Polski"
  ["pl_PL"]="Polski2"
  ["pt_PT"]="Português"
  ["pt_BR"]="Português do Brasil"
  ["ro"]="Română"
  ["ro_MD"]="Română (Moldova)"
  ["sk"]="Slovenčina"
  ["sv"]="Svenska"
  ["th"]="ภาษาไทย"
  ["vi"]="Tiếng Việt"
  ["tr"]="Türkçe"
  ["vi_VN"]="Viet Nam"
  ["ar"]="عربى"
  ["bg_BG"]="български"
  ["bn"]="বাংলা"
  ["el"]="Ελληνικά"
  ["fa"]="فارسی"
  ["hi"]="हिन्दी"
  ["ja"]="日本語"
  ["ka"]="ქართული"
  ["kk"]="Қазақ"
  ["ko_KR"]="한국어"
  ["ru"]="Русский"
  ["sr"]="Српски"
  ["uk"]="Українська"
  ["zh"]="中文"
  ["zh_CN"]="简体中文"
  ["zh_TW"]="中文（台灣)"
)

TEMPLATE_FILE="templates/koreader.pot"
# -------------------- Validation --------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <LANGUAGE_CODE>" >&2
  exit 1
fi

LANG_CODE="$1"

[[ -v LANG_MAP["$LANG_CODE"] ]] || {
  echo "Error: Language code '$LANG_CODE' not supported." >&2
  exit 1
}

[[ -f "$TEMPLATE_FILE" ]] || {
  echo "Error: Template file '$TEMPLATE_FILE' not found." >&2
  exit 1
}

[[ -v API_KEY ]] || {
  echo "Error: API_KEY environment variable not set." >&2
  exit 1
}

LANG_FULLNAME="${LANG_MAP["$LANG_CODE"]}"
PROMPT="${PROMPT_TEMPLATE//__YOUR_LANGUAGE__/$LANG_FULLNAME}"
echo "Translation in progress for $LANG_CODE ($LANG_FULLNAME)."

# -------------------- Create directory --------------------
mkdir -p "$LANG_CODE"
TRANSLATED_FILE="$LANG_CODE/koreader.po"
UNTRANSLATED_FILE="$LANG_CODE/untranslated.po"
UPDATED_TRANSLATED_FILE="$LANG_CODE/updated_translated.po"

INPUTFILE=
OUTPUTFILE=

if [[ ! -f "$TRANSLATED_FILE" && ! -f "$UNTRANSLATED_FILE" ]] then
  # when the target language is untranslated
  cp "$TEMPLATE_FILE" "$UNTRANSLATED_FILE"
  INPUTFILE=$UNTRANSLATED_FILE
  OUTPUTFILE=$TRANSLATED_FILE
elif [[ -f "$TRANSLATED_FILE" && -f "$UNTRANSLATED_FILE" ]] then
  # when target language is updated
  INPUTFILE=$UNTRANSLATED_FILE
  OUTPUTFILE=$UPDATED_TRANSLATED_FILE
else
  echo "translate file not ready for $LANG_CODE ($LANG_FULLNAME)"
  exit 1
fi


# -------------------- Build payload for API request --------------------
PAYLOAD=$(jq -n \
  --arg model "${API_MODEL}" \
  --arg content "$PROMPT" \
  --rawfile file_content "$INPUTFILE" \
  '{
     model: $model,
     messages: [
       {role: "system", content: $content},
       {role: "user",    content: $file_content}
     ],
   }')

# -------------------- Request translation --------------------
RESPONSE=$(curl -Sf -X POST "$API_ENDPOINT" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  --data-raw "$PAYLOAD")

# -------------------- Extract and save result --------------------
echo "$RESPONSE" | jq -r '.choices[0].message.content' \
  > "$OUTPUTFILE"

echo "Translation completed for $LANG_CODE ($LANG_FULLNAME)."
