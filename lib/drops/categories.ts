// What kind of business an offer is from. The same list is in the database
// (offer_categories, in the plans migration); keep the two in step. Quests made
// entirely of one category with a theme get that theme's name.

import type { OfferKind } from "./types";

export const categories: { id: string; name: string; theme: string | null }[] = [
  { id: "coffee", name: "Coffee and tea", theme: "Coffee crawl" },
  { id: "food", name: "Food", theme: "Food trail" },
  { id: "sweets", name: "Bakery and sweets", theme: "Sweet tooth trail" },
  { id: "drinks", name: "Bars and drinks", theme: "Drinks trail" },
  { id: "shopping", name: "Shopping", theme: "Shop hop" },
  { id: "beauty", name: "Beauty and wellness", theme: "Treat yourself trail" },
  { id: "fitness", name: "Fitness and outdoors", theme: "Active trail" },
  { id: "fun", name: "Fun and entertainment", theme: "Fun trail" },
  { id: "services", name: "Services", theme: null },
  { id: "other", name: "Something else", theme: null },
];

export function categoryName(id: string): string {
  return categories.find((c) => c.id === id)?.name ?? "Something else";
}

export const offerKinds: { id: OfferKind; name: string; hint: string }[] = [
  { id: "deal", name: "Coupon or deal", hint: "Money off, or buy one get one." },
  { id: "giveaway", name: "Giveaway", hint: "Something free, like a sample or a gift with a receipt." },
  { id: "gift_card", name: "Gift card", hint: "A gift card or certificate with a set value." },
];

export function offerKindName(kind: OfferKind): string {
  return offerKinds.find((k) => k.id === kind)?.name ?? "Coupon or deal";
}
