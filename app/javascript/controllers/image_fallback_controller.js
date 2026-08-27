import { Controller } from "@hotwired/stimulus";

// A merchant's logo lives on their own site, so the URL can start 404ing long after it was
// saved — a hashed build asset, a redesign, a moved bucket. Without this the portal shows a
// broken-image glyph to that merchant's customers forever. Drop the image instead; the
// heading underneath already names the product.
export default class extends Controller {
  connect() {
    // An image that failed before Stimulus booted fires no error event of its own.
    if (this.element.complete && this.element.naturalWidth === 0) this.hide();
  }

  hide() {
    this.element.remove();
  }
}
