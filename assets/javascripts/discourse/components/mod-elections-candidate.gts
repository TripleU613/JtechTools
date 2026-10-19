import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { eq } from "truth-helpers";
import avatar from "discourse/helpers/avatar";
import icon from "discourse/helpers/d-icon";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import type { ModElectionCandidate } from "../services/mod-elections.ts";

const profileUrl = (username: string): string => getURL(`/u/${username}`);

// One person on the ballot: who they are, whether they hold a seat now, and
// what they wrote about themselves.
const ModElectionsCandidate: TemplateOnlyComponent<{
  Args: { candidate: ModElectionCandidate };
}> = <template>
  <article
    class="mod-elections-candidate
      {{if @candidate.elected 'mod-elections-candidate--elected'}}
      {{if
        (eq @candidate.status 'disqualified')
        'mod-elections-candidate--disqualified'
      }}"
    data-candidate-id={{@candidate.id}}
  >
    {{#if @candidate.user}}
      <a
        class="mod-elections-candidate__avatar"
        data-user-card={{@candidate.user.username}}
        href={{profileUrl @candidate.user.username}}
      >{{avatar @candidate.user imageSize="medium"}}</a>
    {{/if}}
    <div class="mod-elections-candidate__body">
      <div class="mod-elections-candidate__name">
        {{#if @candidate.user}}
          <a
            data-user-card={{@candidate.user.username}}
            href={{profileUrl @candidate.user.username}}
          >{{@candidate.user.username}}</a>
          {{#if @candidate.user.name}}
            <span class="mod-elections-muted">{{@candidate.user.name}}</span>
          {{/if}}
        {{else}}
          <span class="mod-elections-muted">{{i18n
              "mod_elections.candidates.deleted"
            }}</span>
        {{/if}}
        {{#if @candidate.incumbent}}
          <span class="mod-elections-chip">{{icon "shield-halved"}}
            {{i18n "mod_elections.candidates.moderator"}}</span>
        {{/if}}
        {{#if @candidate.elected}}
          <span class="mod-elections-chip mod-elections-chip--strong">{{icon
              "trophy"
            }}
            {{i18n "mod_elections.candidates.elected"}}</span>
        {{/if}}
      </div>
      {{#if @candidate.statement}}
        <p
          class="mod-elections-candidate__statement"
        >{{@candidate.statement}}</p>
      {{/if}}
      {{#if (eq @candidate.status "disqualified")}}
        <p class="mod-elections-candidate__flag">
          {{#if @candidate.disqualified_reason}}
            {{i18n
              "mod_elections.candidates.disqualified"
              reason=@candidate.disqualified_reason
            }}
          {{else}}
            {{i18n "mod_elections.candidates.disqualified_no_reason"}}
          {{/if}}
        </p>
      {{/if}}
    </div>
  </article>
</template>;

export default ModElectionsCandidate;
