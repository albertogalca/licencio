# Gate for the student discount code.
#
# Mirrors src/utils/academicEmail.ts in picmal-marketing — the storefront runs the
# same check in JS to fail fast, but that copy is decoration: anything the browser
# can check, the browser can skip. This one decides whether an email goes out.
#
# ponytail: one regex instead of a domain allowlist. Academic domains in practice put
# `edu` or `ac` as the label before the country code (mit.edu, ox.ac.uk, unimelb.edu.au,
# u-tokyo.ac.jp), so a list would only be a longer way of writing this. Ceiling: schools
# on a plain national domain (uni-koeln.de, ucm.es) fall through and have to email.
module AcademicEmail
  # The country code is capped at two letters on purpose: {2,3} would also swallow
  # edu.com and ac.net.
  PATTERN = /\.(edu|ac)(\.[a-z]{2})?\z/

  def self.match?(email)
    parts = email.to_s.strip.downcase.split("@", -1)
    return false unless parts.size == 2

    local, domain = parts
    return false if local.empty? || domain.empty? || domain.include?("..")
    return false unless domain.match?(/\A[a-z0-9.-]+\z/)

    domain.match?(PATTERN)
  end
end
