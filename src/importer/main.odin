// openwavu-import: user's game files -> content pack of open formats.
package importer

import "core:fmt"
import "core:os"

import tk5 "tk5"

Args :: struct {
	inputs: []string,  // an RPCS3 dir, or a game dir and optionally a .rap
	out:    string,
}

parse_args :: proc(argv: []string) -> (args: Args, ok: bool) {
	args.out = "content"
	inputs := make([dynamic]string)
	for i := 1; i < len(argv); i += 1 {
		if argv[i] == "-o" && i + 1 < len(argv) {
			args.out = argv[i + 1]
			i += 1
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
		fmt.eprintln("usage: openwavu-import <rpcs3 dir | game dir [file.rap]> [-o content]")
		os.exit(2)
	}
	game, err := tk5.find_game(args.inputs)
	if err != "" {
		fmt.eprintln("openwavu-import:", err)
		os.exit(1)
	}
	if err = tk5.run(game, args.out); err != "" {
		fmt.eprintln("openwavu-import:", err)
		os.exit(1)
	}
}
