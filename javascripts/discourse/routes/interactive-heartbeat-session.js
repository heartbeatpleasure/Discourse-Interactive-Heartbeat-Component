import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

export default class InteractiveHeartbeatSessionRoute extends DiscourseRoute {
  model(params) {
    return { token: params.token };
  }

  titleToken() {
    return i18n(themePrefix("interactive_heartbeat.title"));
  }
}
