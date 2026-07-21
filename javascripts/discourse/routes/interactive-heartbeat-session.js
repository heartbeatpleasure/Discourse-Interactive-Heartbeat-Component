import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

export default class InteractiveHeartbeatSessionRoute extends DiscourseRoute {
  async model(params) {
    const token = String(params.token || "");
    const [session, config] = await Promise.all([
      ajax(`/interactive-heartbeat/api/sessions/${token}`),
      ajax("/interactive-heartbeat/api/config"),
    ]);

    return { token, session, config };
  }

  titleToken() {
    return i18n(themePrefix("interactive_heartbeat.title"));
  }
}
