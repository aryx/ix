#!setup touch foo.c
#!args -n foo.5
# :R: rules, \1 in the prerequisites, $stem1 in the recipe
([^/]+)\.5:R: \1.c
	echo 5c $stem1.c stem0=$stem0 stem=$stem
