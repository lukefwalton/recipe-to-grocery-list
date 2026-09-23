# 005 — The grocery list is a pure function (gates 5–6)

v0.1 persisted list membership in a `list_item` table and it was the one piece
of hidden state in the design. SPEC §9 replaced it: the list is computed from
`(selected recipes, manual items, check_state)` on every read, and check state
lives on the **ingredient**, not on a list row. This entry records how that
landed and the two rules that make it hold.

## Membership is a query, checking is a set

`RecipeStore.groceryListInput()` reads, in one `readTransaction`, every
`recipe_ingredients` row whose recipe `is_selected`, joined with its recipe title
and (LEFT JOIN) its ingredient's name and category; the manual items; and the set
of checked ingredient ids. `GroceryListBuilder.build` — `Model/GroceryList.swift`,
Foundation-only, no SQL — turns that into sections in store order (produce,
bakery, dairy, meat, seafood, frozen, pantry, other), one `IngredientGroup` per
canonical with its constituent lines underneath, unchecked groups first and
checked ones sunk to the bottom of their category, then by name. Rows kept as
text and manual items live under **Other** and are never merged with anything.
`GroceryListTests` (19 cases) and a Python mirror of the algorithm pin the
ordering; nothing about membership is ever written.

## Honest sums (§8)

`GroceryListBuilder.sum(of:)` returns a sum only when a group has **two or more
lines**, every line has a quantity, and every `unit_key` is equal — where two
`nil` keys count as equal ("2 onions" + "1 onion" → 3). Cups are never added to
millilitres, a line without a quantity poisons the whole group's sum, and a
single line shows no sum because it would only repeat itself. The lines are
always shown; the sum sits beside them. `QuantityFormat` renders common eighths
and thirds as fractions and everything else to one decimal.

## Check-state survival and the GC that makes it true

Checking an ingredient heading inserts one `check_state` row keyed by
`ingredient_id`, so the check survives regenerating the list, adding a second
recipe that also needs garlic, or removing one of them. The only way a check
disappears on its own is the GC: when no *selected* recipe contributes the
ingredient any more, its `check_state` row is deleted **in the same transaction**
as the selection change or the delete —

```sql
DELETE FROM check_state WHERE ingredient_id NOT IN (
    SELECT ri.ingredient_id FROM recipe_ingredients ri
    JOIN recipes r ON r.id = ri.recipe_id
    WHERE r.is_selected = 1 AND ri.ingredient_id IS NOT NULL
);
```

— otherwise re-selecting a recipe next week would show stale checks. `setSelected`,
`deleteRecipe`, `deselectAllRecipes` and `doneShopping` all run it; `setChecked`
does not (checking never changes membership). The two-recipes-share-garlic case
is the test: deselect one, the check stays; deselect the other, it is gone.

## Destructive actions come in one pair

*Clear checked* deletes every `check_state` row and every checked manual item;
*Deselect all recipes* deselects and GCs. **Done shopping** is both, in one store
transaction (`doneShopping`), behind one confirmation. There is deliberately no
"undo" — the list is a function of state the user can re-create by re-selecting.

## Where the seam for v1.1 is

Because the list is a value type (`GroceryList` is `Equatable`, built from
`GroceryListInput`), exporting it to Reminders via EventKit later is a
transformation of that value, not a schema change.
