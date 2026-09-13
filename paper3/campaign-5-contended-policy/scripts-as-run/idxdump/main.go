// idxdump dumps the stargz cache-accounting index read-only, for spike v5's V6
// derived access trace.
//
// It is deliberately NOT part of the system under test: it is its own module, it
// is never linked into the snapshotter, and it opens a COPY of the bolt file so
// it can neither take the writer's lock nor perturb the timing being measured.
//
// Record layout is cache/accounting/store.go @ f6547d99: 33 bytes, big-endian,
//
//	size int64 | at int64 | addedAt int64 | firstHitAt int64 | cacheType uint8
//
// If that layout ever changes, this prints nothing rather than garbage: the
// length check below is the canary.
package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"time"

	bolt "go.etcd.io/bbolt"
)

const recordSize = 33

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: idxdump <cache-accounting.db>")
		os.Exit(2)
	}
	db, err := bolt.Open(os.Args[1], 0400, &bolt.Options{ReadOnly: true, Timeout: 5 * time.Second})
	if err != nil {
		fmt.Fprintf(os.Stderr, "open: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	fmt.Println("# key\tsize\tat\taddedAt\tfirstHitAt\tcacheType")
	n, bad := 0, 0
	err = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("chunks"))
		if b == nil {
			return fmt.Errorf("no chunks bucket")
		}
		return b.ForEach(func(k, v []byte) error {
			if len(v) != recordSize {
				bad++
				return nil
			}
			fmt.Printf("%s\t%d\t%d\t%d\t%d\t%d\n", k,
				int64(binary.BigEndian.Uint64(v[0:8])),
				int64(binary.BigEndian.Uint64(v[8:16])),
				int64(binary.BigEndian.Uint64(v[16:24])),
				int64(binary.BigEndian.Uint64(v[24:32])),
				v[32])
			n++
			return nil
		})
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "view: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "dumped=%d malformed=%d\n", n, bad)
	if bad > 0 && n == 0 {
		fmt.Fprintln(os.Stderr, "WARNING: every record had an unexpected length -- record layout changed?")
		os.Exit(3)
	}
}
