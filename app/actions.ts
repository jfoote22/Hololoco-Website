"use server";

import { updateTag } from "next/cache";
import { dropTag } from "@/lib/drops/page";

/**
 * Called after someone saves, pauses or deletes their drop, so its page and link
 * preview stop showing the old version. The database has already checked they
 * were allowed to; this only clears cached copies.
 */
export async function dropChanged(id: string): Promise<void> {
  if (typeof id !== "string" || !/^[a-z0-9]{4,16}$/.test(id)) return;
  updateTag(dropTag(id));
}
