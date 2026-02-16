@{
  Locale = "en"
  Templates = @{
    # =========================================================================
    # TRANSLATOR GUIDELINES (PLEASE READ):
    # =========================================================================
    # 1. TECHNICAL TAGS: [*], [+], [-], [!] 
    #    - These are log prefixes. Keep them at the START of the string.
    #    - DO NOT translate or remove them unless specifically requested.
    #
    # 2. PLACEHOLDERS: {0}, {1}, {2}...
    #    - These are dynamic values (mod names, counts, paths).
    #    - MANDATORY: Must be present in the translated string.
    #    - You CAN change their order if required by target language grammar.
    #
    # 3. LABELS IN BRACKETS: [core], [layer], [tier]
    #    - Technical categories. 
    #    - IMPORTANT: To translate these, edit the 'Substrings' section below.
    #    - DO NOT change them inside 'Templates' unless you want a unique override.
    #
    # 4. INPUT HINTS: <KEY_...>
    #    - Technical tags. Actual key values are injected from code.
    #    - DO NOT rename/remove tags (for example, <KEY_RETRY_HINT>).
    #
    # 5. SPECIAL CHARACTERS:
    #    - `n  : Literal newline (PowerShell format).
    #    - \" : Escaped double quote inside the string.
    #
    # 6. DEBUG/VERBOSE STRINGS:
    #    - Write-Verbose / debug-only messages stay in English intentionally.
    #    - They are excluded from translation coverage in tools/Check-Localization.py.
    # =========================================================================

    # * Source code is now English. Add overrides here if needed.
  }
  Substrings = @{
    # =========================================================================
    # GLOBAL TERMINOLOGY (Substrings):
    # These are automatically replaced inside ANY string.
    # =========================================================================
    "[core]"  = "[core]"
    "[layer]" = "[layer]"
    "[tier]"  = "[tier]"
    "tier"    = "tier"
    # * Stage Names
    "Baseline Analysis" = "Baseline Analysis"
    "Mixin Analysis"    = "Mixin Analysis"
    "Layering"          = "Layering"
    "Isolation"         = "Isolation"
  }
  Ui = @{
    CrashWindowTitlePatterns = @(
      "Something broke..."
    )
  }
}
