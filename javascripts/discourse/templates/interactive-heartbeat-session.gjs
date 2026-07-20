import RouteTemplate from "ember-route-template";
import InteractiveHeartbeatSessionPage from "../components/interactive-heartbeat-session-page";

export default RouteTemplate(
  <template>
    <InteractiveHeartbeatSessionPage @token={{@model.token}} />
  </template>,
);
