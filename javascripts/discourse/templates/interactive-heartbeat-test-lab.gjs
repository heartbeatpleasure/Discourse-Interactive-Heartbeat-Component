import RouteTemplate from "ember-route-template";
import InteractiveHeartbeatTestLabPage from "../components/interactive-heartbeat-test-lab-page";

export default RouteTemplate(
  <template>
    <InteractiveHeartbeatTestLabPage @config={{@model}} />
  </template>,
);
