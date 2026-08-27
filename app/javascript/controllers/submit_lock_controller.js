import { Controller } from "@hotwired/stimulus";

// These forms POST, and the controller then calls Stripe and 302s to checkout. That round
// trip is a second or so of dead page, and they run with turbo: false, so Turbo's own submit
// state never applies. Without a lock an impatient second click buys a second checkout
// session. Fires on `submit`, so a form that fails its own validation is never locked.
export default class extends Controller {
  static targets = ["button"];

  lock() {
    // Disable after the browser has serialised the form, never before.
    setTimeout(() => {
      this.buttonTargets.forEach((button) => {
        if (button.dataset.lockedLabel) button.value = button.dataset.lockedLabel;
        button.disabled = true;
      });
    }, 0);
  }
}
