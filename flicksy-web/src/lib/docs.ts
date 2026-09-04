import { getCollection, type CollectionEntry } from 'astro:content';

export type DocEntry = CollectionEntry<'docs'>;

export async function getDocs(): Promise<DocEntry[]> {
  const docs = await getCollection('docs');
  return docs.sort((left, right) => left.data.order - right.data.order || left.id.localeCompare(right.id));
}

export function docPath(entry: DocEntry): string {
  return `/docs/${entry.id}`;
}

export function adjacentDocs(docs: DocEntry[], slug: string) {
  const index = docs.findIndex((entry) => entry.id === slug);
  return {
    previous: index > 0 ? docs[index - 1] : undefined,
    next: index >= 0 && index < docs.length - 1 ? docs[index + 1] : undefined,
  };
}
