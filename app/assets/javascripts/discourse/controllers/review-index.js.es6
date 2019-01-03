export default Ember.Controller.extend({
  reviewables: null,

  actions: {
    remove(reviewable) {
      this.get("reviewables").removeObject(reviewable);
    }
  }
});
