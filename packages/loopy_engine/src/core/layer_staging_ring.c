#include "layer_staging_ring.h"

#include <stdlib.h>

static int is_power_of_two(size_t n) { return n >= 2 && (n & (n - 1)) == 0; }

int le_layer_staging_ring_init(le_layer_staging_ring* ring,
                               le_staged_layer* buffer, size_t capacity) {
  if (ring == NULL || buffer == NULL || !is_power_of_two(capacity)) {
    return 0;
  }
  ring->buffer = buffer;
  ring->capacity = capacity;
  ring->mask = capacity - 1;
  atomic_store_explicit(&ring->head, 0, memory_order_relaxed);
  atomic_store_explicit(&ring->tail, 0, memory_order_relaxed);
  return 1;
}

int le_layer_staging_ring_push(le_layer_staging_ring* ring,
                               le_staged_layer entry) {
  /* Producer owns tail; it only needs an acquire view of head to test
   * fullness. */
  const size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
  const size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
  if (tail - head >= ring->capacity - 1) {
    return 0; /* full */
  }
  ring->buffer[tail & ring->mask] = entry;
  /* Release so the consumer sees the slot write before the new tail. */
  atomic_store_explicit(&ring->tail, tail + 1, memory_order_release);
  return 1;
}

int le_layer_staging_ring_pop(le_layer_staging_ring* ring,
                              le_staged_layer* out) {
  const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
  const size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
  if (head == tail) {
    return 0; /* empty */
  }
  *out = ring->buffer[head & ring->mask];
  atomic_store_explicit(&ring->head, head + 1, memory_order_release);
  return 1;
}

void le_layer_staging_ring_drain_free(le_layer_staging_ring* ring) {
  if (ring == NULL || ring->buffer == NULL) return;
  le_staged_layer entry;
  while (le_layer_staging_ring_pop(ring, &entry)) {
    for (int32_t l = 0; l < entry.lane_count && l < LE_MAX_LANES; ++l) {
      free(entry.lane_pcm[l]);
    }
  }
}
