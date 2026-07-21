import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

export default class InteractiveHeartbeatTestLabRoute extends DiscourseRoute {
  async model() {
    return ajax("/interactive-heartbeat/api/config");
  }

  titleToken() {
    return i18n(themePrefix("interactive_heartbeat.test_lab.title"));
  }
}
