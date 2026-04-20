# BM25 + Fusion Search Validation Corpus

This document is designed to surface retrieval differences between BM25-only,
vector-only, and fused search. Each section is labelled with which retrieval
leg it is expected to favour.

---

## Section A — Exact Keyword Match (BM25 wins)

The Reciprocal Rank Fusion algorithm, abbreviated RRF, combines ranked lists
from heterogeneous retrieval systems by summing reciprocal rank scores. The
formula is: RRF(d) = Σ 1/(k + rank_i(d)) where k is a smoothing constant
typically set to 60. RRF is rank-based, not score-based, so it is robust to
score-scale differences between BM25 and cosine similarity. Practitioners
report that RRF outperforms linear score combination in most ad-hoc retrieval
benchmarks without requiring any hyperparameter tuning beyond k.

---

## Section B — Semantic Paraphrase (vector wins)

Merging results from keyword search and dense retrieval improves recall for
questions where neither system alone surfaces the best document. By assigning
each candidate a position-based weight and aggregating across both lists, the
combined ranker rewards documents that appear consistently near the top
regardless of the individual scoring function used. This approach does not
require training and generalises across domains.

---

## Section C — Fusion beats both (shared signal)

The BM25 scoring function extends TF-IDF by applying a saturation curve to
term frequency and a document length normalisation factor. For a query term t
in document d: BM25(t,d) = IDF(t) * (tf * (k1+1)) / (tf + k1*(1 - b + b*dl/avgdl)).
Combining BM25 with vector similarity via Reciprocal Rank Fusion consistently
outperforms either system alone on the BEIR benchmark suite.

---

## Section D — False BM25 Hit (vector corrects it)

The bank processed a large batch of transactions using a ranked priority
queue. Each transaction had a score assigned by the fraud detection model.
The top-ranked items were flagged for manual review. The system combined
scores from two independent models using a weighted average formula.

---

## Section E — Multilingual: French

La fusion hybride combine la recherche par mots-clés et la recherche
sémantique vectorielle pour améliorer la pertinence des résultats. L'algorithme
de fusion par rang réciproque attribue à chaque document un score basé sur sa
position dans chaque liste classée. Cette approche est particulièrement
efficace pour les requêtes contenant des termes techniques précis, car la
recherche BM25 détecte les correspondances exactes que les embeddings peuvent
manquer. Les systèmes modernes de recherche d'information combinent ces deux
approches pour obtenir de meilleures performances.

---

## Section F — Multilingual: Spanish

La búsqueda híbrida combina la recuperación léxica basada en BM25 con la
búsqueda semántica vectorial para mejorar la precisión y la exhaustividad. El
algoritmo de fusión por rango recíproco asigna a cada documento una puntuación
basada en su posición en las listas ordenadas. Esta técnica es especialmente
útil cuando las consultas contienen términos técnicos específicos que los
modelos de embeddings pueden no capturar correctamente. Los sistemas modernos
de recuperación de información utilizan esta combinación para obtener mejores
resultados en todos los dominios.

---

## Section G — Multilingual: Arabic

البحث الهجين يجمع بين البحث المعتمد على الكلمات المفتاحية باستخدام خوارزمية
BM25 والبحث الدلالي المعتمد على التضمينات المتجهية لتحسين جودة نتائج البحث.
تعتمد خوارزمية دمج الترتيب التبادلي على تعيين درجة لكل وثيقة بناءً على
موضعها في قوائم الترتيب المختلفة. هذا النهج فعّال بشكل خاص للاستعلامات
التي تحتوي على مصطلحات تقنية دقيقة حيث يكتشف BM25 التطابقات الدقيقة التي
قد تفوت نماذج التضمين. تستخدم أنظمة استرجاع المعلومات الحديثة هذا النهج
المدمج للحصول على نتائج أفضل عبر مختلف المجالات والتطبيقات.

---

## Section H — Short chunk

RRF k=60.
