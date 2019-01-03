export function formatCurrency([reviewable, fieldId]) {
  // The field `category_id` corresponds to `category`
  if (fieldId === "category_id") {
    fieldId = "category.id";
  }
  return Ember.get(reviewable, fieldId);
}

export default Ember.Helper.helper(formatCurrency);
