local _ = require("l10n.gettext")
return {
    -- we have to lie here and claim to be coverbrowser now that there are explicit calls from core koreader
    -- name = "projecttitle",
    name = "coverbrowser",
    fullname = _("Project: Title"),
    description = _([[Alternative display modes for file browser and history.]]),
}
