import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "copyIcon", "checkIcon"];

  copy() {
    if (!navigator.clipboard) return this.select();
    navigator.clipboard.writeText(this.sourceTarget.value).then(
      () => this.confirm(),
      () => this.select(),
    );
  }

  confirm() {
    this.copyIconTarget.classList.add("hidden");
    this.checkIconTarget.classList.remove("hidden");
    setTimeout(() => {
      this.checkIconTarget.classList.add("hidden");
      this.copyIconTarget.classList.remove("hidden");
    }, 1500);
  }

  select() {
    this.sourceTarget.select();
  }
}
