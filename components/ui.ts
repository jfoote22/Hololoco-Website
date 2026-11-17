// Shared classes for form controls, so every screen's fields and buttons match.

export const inputClass =
  "min-h-11 w-full rounded-lg border border-line bg-surface px-3 text-base outline-none focus:border-accent";

export const labelClass = "flex flex-col gap-1 text-sm font-medium";

export const primaryButton =
  "flex min-h-12 items-center justify-center gap-2 rounded-xl bg-accent px-4 font-semibold text-on-accent hover:bg-accent-strong disabled:opacity-60";

export const secondaryButton =
  "flex min-h-12 items-center justify-center gap-2 rounded-xl border border-line bg-surface px-4 font-semibold hover:bg-wash disabled:opacity-60";

export const textButton = "flex min-h-11 items-center px-1 text-sm font-medium text-accent hover:underline";

/** A radio or checkbox drawn as a card: the native input stays, for keyboards and screen readers. */
export const choiceCard =
  "flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-line p-3 has-checked:border-accent has-checked:bg-accent-wash has-focus-visible:outline-2 has-focus-visible:outline-accent";
