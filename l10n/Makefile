.PHONY: all translate template update extract-untranslated ai-translate check-ai-results import-translation check clean

all: translate

# This target runs the full translation pipeline:
# 1. Extracts strings from source code into a .pot template.
# 2. Merges the template into language .po files.
# 3. Extracts all untranslated strings.
# 4. Runs the AI translation script on them.
# 5. Verifies that AI translation produced output files.
# 6. Merges the new translations back into the .po files.
# 7. Checks the syntax of the final .po files.
# 8. Cleans up all intermediate files.
translate:
	@if [ -z "$(API_KEY)" ]; then \
		echo "\033[0;31mError: API_KEY environment variable is not set.\033[0m"; \
		echo "Please set it before running translation. e.g., export API_KEY=your_key"; \
		exit 1; \
	fi
	@echo "[1/9] Generating POT template file..."
	@$(MAKE) template
	@echo "[2/9] Merging POT file into PO files..."
	@$(MAKE) update
	@echo "[3/9] Generating untranslated files..."
	@$(MAKE) extract-untranslated
	@echo "[4/9] Running AI translation..."
	@$(MAKE) ai-translate
	@echo "[5/9] Verifying AI translation results..."
	@$(MAKE) check-ai-results
	@echo "[6/9] Merging untranslated files..."
	@$(MAKE) import-translation
	@echo "[7/9] Checking PO files..."
	@$(MAKE) check
	@echo "[8/9] Cleaning up intermediate files..."
	@$(MAKE) clean
	@echo "[9/9] Translation process completed successfully!"
	@$(MAKE) convert-to-mo


DOMAIN = koreader
TEMPLATE_DIR = templates
MSGFMT_BIN = msgfmt
MSGMERGE_BIN = msgmerge
MSGATTRIB_BIN = msgattrib
MSGCAT_BIN = msgcat
XGETTEXT_BIN = xgettext

PO_FILES  := $(wildcard */$(DOMAIN).po)
LANGS     := $(patsubst %/,%,$(filter-out templates/,$(wildcard */)))

update: template
	@for po_file in $(PO_FILES); do \
		$(MSGMERGE_BIN) --update --no-fuzzy-matching --backup=none $$po_file $(TEMPLATE_DIR)/$(DOMAIN).pot; \
		$(MSGATTRIB_BIN) --no-obsolete -i $$po_file -o $$po_file; \
	done

extract-untranslated:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		$(MSGATTRIB_BIN) --untranslated $$po_file -o $$dir/untranslated.po; \
	done

check-ai-results:
	@set -e; \
	for lang in $(LANGS); do \
		if [ -s "$$lang/untranslated.po" ]; then \
			if [ ! -f "$$lang/updated_translated.po" ]; then \
				echo "\033[0;31mError: AI translation for '$$lang' failed.\033[0m"; \
				echo "File '$$lang/updated_translated.po' was not created, but '$$lang/untranslated.po' was not empty."; \
				echo "This might be due to an API error or network issue."; \
				echo "Please check the output above for any error messages from the AI translation script."; \
				echo "You can try running the translation for this language again with: make ai-translate L10N_LANG=$$lang"; \
				exit 1; \
			fi; \
		fi; \
	done

import-translation:
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		if [ -f "$$dir/updated_translated.po" ]; then \
			$(MSGCAT_BIN) --use-first $$dir/updated_translated.po $$po_file -o updated.po; \
			mv updated.po $$po_file; \
		fi; \
	done

check:
	@echo "Checking syntax of existing .po files..."
	@for po_file in $(PO_FILES); do \
		$(MSGFMT_BIN) --check -o /dev/null $$po_file; \
	done

clean:
	@echo "Cleaning intermediate translation files..."
	@find . -type f \( -name "untranslated.po" -o -name "updated_translated.po" -o -name "updated.po" \) -print -delete

ai-translate:
	@set -e; \
	if [ -n "$(L10N_LANG)" ]; then \
		echo "Translating language $(L10N_LANG)..."; \
		./AI_TRANSLATE.sh $(L10N_LANG); \
	else \
		TO_TRANSLATE=$$(for lang in $(LANGS); do if [ -s "$$lang/untranslated.po" ]; then echo $$lang; fi; done); \
		TOTAL=$$(echo $$TO_TRANSLATE | wc -w); \
		COUNT=0; \
		for lang in $$TO_TRANSLATE; do \
			COUNT=$$((COUNT+1)); \
			echo "Translating language $$COUNT of $$TOTAL ($$lang)..."; \
			./AI_TRANSLATE.sh $$lang && { \
				FILE_SIZE=$$(wc -c < "$$lang/untranslated.po"); \
				if [ $$FILE_SIZE -gt 5120 ]; then \
					echo "... waiting 30s to avoid API rate limits (large file)"; \
					sleep 30; \
				else \
					echo "... waiting 10s to avoid API rate limits"; \
					sleep 10; \
				fi; \
			}; \
		done; \
		if [ -z "$$TO_TRANSLATE" ]; then \
			echo "All languages are up to date. Nothing to translate."; \
		fi; \
	fi

template:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT_BIN) --from-code=utf-8 \
		--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
		--add-comments=@translators \
		--package-name=projecttitle.koplugin \
		--package-version=`grep version ../_meta.lua | grep -Eo '[0-9.]+'` \
		`find .. -name "*.lua" | sort` \
		-o $(TEMPLATE_DIR)/$(DOMAIN).pot

convert-to-mo:
	@echo "Converting .po files to .mo..."
	@for po_file in $(PO_FILES); do \
		dir=$$(dirname $$po_file); \
		lang=$$(basename $$dir); \
		$(MSGFMT_BIN) -o $$dir/$(DOMAIN).mo $$po_file; \
		echo "Compiled $$po_file → $$dir/$(DOMAIN).mo"; \
	done
