import Foundation

/// Deterministic fuzzy string similarity — layer 2 of the resolution stack
/// (spec §7.4). Jaro–Winkler catches short typos ("tomatos" → "tomato"); a token
/// metric catches multi-word names ("veggie stock" → "vegetable stock").
///
/// **Food-specific tightening** (see `docs/learnings/003-fuzzy-thresholds.md`): the
/// workout app averages only over the *query's* tokens, which lets a short query
/// score 1.0 against any longer name containing it — exactly the substring trap the
/// spec warns about (`cream` → "sour cream", `chicken` → "chicken broth"). Here the
/// token metric is **symmetric**: the minimum of both directions, so a query has to
/// account for the candidate's words too. `smoked paprika` no longer collapses onto
/// `paprika`, and `chicken` stays `chicken`.
///
/// The whole-string Jaro–Winkler has the same trap from the other side: a short query
/// that is a *prefix* of a longer name matches every one of its own characters and
/// then collects the 4-character prefix bonus (`chicken` vs `chicken broth` scored
/// 0.91; `garlic` vs `garlic powder` 0.89). So the whole-string score is consulted
/// only when both sides have the same number of words — its job is single-word typos
/// (`mozzarela`) and same-shape multi-word typos (`bell peper`); when the word counts
/// differ, the symmetric token metric alone decides. Verified against a Python port
/// before the threshold tests were written; that port is committed as
/// `scripts/reference_parser.py`, whose `--selftest` pins seventeen similarity
/// values against this file's documented behaviour.
///
/// The **head noun** is the last guard, and the one the golden corpus insisted on.
/// A shared modifier was still carrying whole matches: `grated gruyère` scored 0.87
/// against the alias *grated nutmeg*, and `shredded carot` 0.92 against *shredded
/// cheddar*, purely on the first word. In a food name the identity lives in the
/// last word — "grated X" is X — so a pair is capped at its head nouns' similarity.
/// True matches are unaffected (their heads agree: `veggie broth`/`vegetable broth`
/// = 1.00, `bell peper`/`bell pepper` = 0.96), while those two traps fall to 0.54
/// and 0.50. Measured over the whole corpus: four false matches removed, nothing
/// else moved (`docs/learnings/003-fuzzy-thresholds.md`).
///
/// Jaro–Winkler is the published algorithm (Jaro 1989, Winkler 1990), re-implemented
/// here rather than vendored (family rule: port, don't depend). Pure and unit-tested;
/// the threshold lives with `IngredientResolver`, calibrated on the golden corpus.
enum FuzzyMatch {
    /// 0…1 similarity of a query to one candidate string. Both sides go through the
    /// same §7.1 normalization so plurals and casing never count as differences.
    static func similarity(_ query: String, _ candidate: String) -> Double {
        let q = IngredientNormalizer.normalize(query)
        let c = IngredientNormalizer.normalize(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c { return 1 }
        let tokenScore = tokenSimilarity(q, c)
        // Different word counts: the extra word must cost something, and only the
        // token metric charges for it (see the type comment).
        let score: Double
        if tokens(q).count == tokens(c).count {
            score = max(jaroWinkler(q, c), tokenScore)
        } else {
            score = tokenScore
        }
        // Two ingredient names are at most as similar as their head nouns.
        guard let queryHead = tokens(q).last, let candidateHead = tokens(c).last else { return score }
        return min(score, jaroWinkler(queryHead, candidateHead))
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Symmetric token similarity: the smaller of the two directed averages, so
    /// neither side's extra words are free.
    static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        min(directedTokenSimilarity(a, b), directedTokenSimilarity(b, a))
    }

    /// Average over `query` tokens of the best Jaro–Winkler match among `candidate`
    /// tokens (the workout app's one-directional metric).
    static func directedTokenSimilarity(_ query: String, _ candidate: String) -> Double {
        let queryTokens = tokens(query), candidateTokens = tokens(candidate)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }
        let total = queryTokens.reduce(0.0) { sum, q in
            sum + (candidateTokens.map { jaroWinkler(q, $0) }.max() ?? 0)
        }
        return total / Double(queryTokens.count)
    }

    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let j = jaro(a, b)
        var prefix = 0
        for (x, y) in zip(a, b) {
            if x == y && prefix < 4 { prefix += 1 } else { break }
        }
        return j + Double(prefix) * 0.1 * (1 - j)
    }

    static func jaro(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let s1 = Array(a), s2 = Array(b)
        if s1.isEmpty || s2.isEmpty { return 0 }
        let matchDistance = max(max(s1.count, s2.count) / 2 - 1, 0)
        var s1Matched = [Bool](repeating: false, count: s1.count)
        var s2Matched = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in s1.indices {
            let lo = max(0, i - matchDistance)
            let hi = min(i + matchDistance + 1, s2.count)
            var j = lo
            while j < hi {
                if !s2Matched[j], s2[j] == s1[i] {
                    s1Matched[i] = true; s2Matched[j] = true; matches += 1; break
                }
                j += 1
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0, k = 0
        for i in s1.indices where s1Matched[i] {
            while !s2Matched[k] { k += 1 }
            if s1[i] != s2[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let halfTranspositions = Double(transpositions) / 2.0
        return (m / Double(s1.count) + m / Double(s2.count) + (m - halfTranspositions) / m) / 3
    }
}
