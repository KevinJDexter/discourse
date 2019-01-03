import RestAdapter from "discourse/adapters/rest";

export default RestAdapter.extend({
  pathFor(store, type, findArgs) {
    return this.appendQueryParams("/review", findArgs);
  }
});
