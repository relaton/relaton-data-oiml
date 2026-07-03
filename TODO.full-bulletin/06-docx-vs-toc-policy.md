# 06 — Policy: docx vs printed TOC authority

## Problem

1980 no.80 has 18 entries in the docx but only 7 appear in the
Bulletin's printed SOMMAIRE (verified via GLM OCR). The other 11 are
genuine articles — they appear in the issue body but not in the
printed TOC. Examples:

- *"Notre nouveau Président : Monsieur Knut BIRKELAND"*
- *"Societal and technological demands upon legal metrology — A strategy
  for meeting increased..."*
- *"REPUBLIQUE FEDERALE d'ALLEMAGNE — Zur Eichung von Kohlenmonoxid-
  Messgeräten für das Abgas..."*
- *"TCHECOSLOVAQUIE — L'influence de la métrologie sur la qualité des
  produits, par T. BILL..."*
- *"Accord de coopération avec l'ONUDI"*

Similar patterns likely exist in other pre-1995 issues where the
printed TOC was selective but the docx editor listed every article.

## Question

When the docx and the printed Bulletin TOC disagree, which is
authoritative for this dataset?

## Options

**A. Docx is authoritative (current behavior)**
- Pros: Complete coverage; editor's deliberate compilation
- Cons: Includes items the printed issue didn't promote to its TOC;
  may over-count "articles" by including short country reports
- Implementation: do nothing; current dataset already reflects this

**B. Printed TOC is authoritative**
- Pros: Matches what readers of the actual Bulletin saw
- Cons: Loses genuine content; requires re-OCR of every issue to
  enforce
- Implementation: drop the 11 extras from 1980 no.80; audit other
  pre-1995 issues similarly

**C. Hybrid — both, with a subtype tag**
- Pros: Preserves both views; lets consumers choose
- Cons: More modeling overhead; need a `toc_included: true/false` ext
  field or similar
- Implementation: add `ext.toc_included` to article records; default
  true; mark the 11 extras as `false`

## Recommendation

**Option A** (status quo). The dataset's purpose is to be a complete
bibliographic record of Bulletin content, not a reproduction of any
single issue's printed TOC. The docx editor's compilation is more
complete; the printed TOC was constrained by physical layout. Document
this policy in AGENTS.md so future contributors know the dataset is
intentionally more inclusive than the printed TOCs.

## Acceptance

- Maintainer confirms the policy choice (recommended: A)
- AGENTS.md updated with a "Docx authority" section noting that docx
  entries may exceed printed TOC content
- Issue #4 finding 7 closed with the policy decision recorded
- No data changes if Option A (the recommended default)
