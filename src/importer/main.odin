// openwavu-import: user's game files -> the game's stock title pack (packs/tekken5dr.tar).
package importer

import "core:fmt"
import "core:os"

import tk5 "tk5"

Args :: struct {
	inputs: []string,  // an RPCS3 dir, or a game dir and optionally a .rap
	out:    string,
	keep:   bool,  // keep the unpacked files in <out>/tekken5dr/
}

parse_args :: proc(argv: []string) -> (args: Args, ok: bool) {
	args.out = "packs"
	inputs := make([dynamic]string)
	for i := 1; i < len(argv); i += 1 {
		if argv[i] == "-o" && i + 1 < len(argv) {
			args.out = argv[i + 1]
			i += 1
		} else if argv[i] == "-keep" {
			args.keep = true
		} else {
			append(&inputs, argv[i])
		}
	}
	args.inputs = inputs[:]
	return args, len(args.inputs) > 0
}

main :: proc() {
	args, ok := parse_args(os.args)
	if !ok {
		fmt.eprintln("usage: openwavu-import <rpcs3 dir | game dir [file.rap]> [-o packs] [-keep]")
		os.exit(2)
	}
	if err := tk5.build_pack(args.inputs, args.out, args.keep); err != "" {
		fmt.eprintln("openwavu-import:", err)
		os.exit(1)
	}
}
