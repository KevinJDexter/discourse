import RestModel from "discourse/models/rest";
import computed from "ember-addons/ember-computed-decorators";
import Category from "discourse/models/category";

export default RestModel.extend({
  @computed("type")
  humanType(type) {
    return I18n.t(`review.types.${type.underscore()}.title`, {
      defaultValue: ""
    });
  },

  update(updates) {
    // If no changes, do nothing
    if (Object.keys(updates).length === 0) {
      return Ember.RSVP.resolve();
    }

    return this.store.update("reviewable", this.id, updates).then(result => {
      let updated = result.responseJson;
      updated.payload = Object.assign(
        {},
        this.get("payload") || {},
        updated.payload || {}
      );

      if (updated.category_id) {
        updated.category = Category.findById(updated.category_id);
        delete updated.category_id;
      }

      this.setProperties(updated);
    });
  }
});
