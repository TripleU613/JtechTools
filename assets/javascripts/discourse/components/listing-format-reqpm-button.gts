import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import type Post from "discourse/models/post";
import ReqpmService from "../services/reqpm.ts";

type ListingPost = Post & {
  user_id: number;
  username: string;
  name?: string | null;
  avatar_template?: string;
};

interface ListingFormatReqpmButtonSignature {
  Args: { post: ListingPost; showLabel?: boolean };
  Element: HTMLButtonElement | HTMLAnchorElement;
}

// REQ-PM on a listing: the seller's REQ-PM window, the same one their user
// card opens, where buyers ask for contact details instead of replying in
// the thread. Not a private message, which the forum doesn't allow. The
// initializer only adds it for people who can use REQ-PM; REQ-PM itself
// says when a seller can't be reached.
export default class ListingFormatReqpmButton extends Component<ListingFormatReqpmButtonSignature> {
  @service declare reqpm: ReqpmService;

  @action
  open() {
    const { post } = this.args;
    this.reqpm.openUser({
      id: post.user_id,
      username: post.username,
      name: post.name,
      avatar_template: post.avatar_template,
    });
  }

  <template>
    <DButton
      class="btn-default listing-format-reqpm"
      ...attributes
      @action={{this.open}}
      @icon="address-card"
      @label="reqpm.button.label"
      @title="reqpm.button.title"
    />
  </template>
}
