SRC_DIR := qubes-src

#Include config file
BUILDERCONF ?= builder.conf
-include $(BUILDERCONF)

# Set defaults
BRANCH ?= master
GIT_BASEURL ?= git://github.com
GIT_SUFFIX ?= .git
DIST_DOM0 ?= fc20
DISTS_VM ?= fc20
VERBOSE ?= 0

# Beware of build order
COMPONENTS ?= builder

LINUX_REPO_BASEDIR ?= $(SRC_DIR)/linux-yum/current-release
INSTALLER_COMPONENT ?= installer-qubes-os
BACKEND_VMM ?= xen
KEYRING_DIR_GIT ?= $(PWD)/keyrings/git

ifdef GIT_SUBDIR
  GIT_PREFIX ?= $(GIT_SUBDIR)/
endif

# checking for make from Makefile is pointless
DEPENDENCIES ?= git rpmdevtools rpm-build createrepo #make

ifneq (1,$(NO_SIGN))
  DEPENDENCIES += rpm-sign
endif

# Get rid of quotes
DISTS_VM := $(shell echo $(DISTS_VM))
NO_CHECK := $(shell echo $(NO_CHECK))

DISTS_ALL := $(filter-out $(DIST_DOM0),$(DISTS_VM)) $(DIST_DOM0)

GIT_REPOS := $(addprefix $(SRC_DIR)/,$(filter-out builder,$(COMPONENTS)))

ifneq (,$(findstring builder,$(COMPONENTS)))
GIT_REPOS += .
endif

check_branch = if [ -n "$(1)" -a "0$(CHECK_BRANCH)" -ne 0 ]; then \
				   BRANCH=$(BRANCH); \
				   branch_var="BRANCH_$(subst -,_,$(1))"; \
				   [ -n "$${!branch_var}" ] && BRANCH="$${!branch_var}"; \
				   pushd $(SRC_DIR)/$(1) > /dev/null; \
				   CURRENT_BRANCH=`git branch | sed -n -e 's/^\* \(.*\)/\1/p' | tr -d '\n'`; \
				   if [ "$$BRANCH" != "$$CURRENT_BRANCH" ]; then \
					   echo "-> ERROR: Wrong branch $$CURRENT_BRANCH (expected $$BRANCH)"; \
					   exit 1; \
				   fi; \
				   popd > /dev/null; \
			   fi; 


.EXPORT_ALL_VARIABLES:
.ONESHELL:
help:
	@echo "make qubes            -- download and build all components"
	@echo "make qubes-dom0       -- download and build all dom0 components"
	@echo "make qubes-vm         -- download and build all VM components"
	@echo "make get-sources      -- download/update all sources"
	@echo "make sign-all         -- sign all packages"
	@echo "make clean-all        -- remove any downloaded sources and built packages"
	@echo "make clean-rpms       -- remove any built packages"
	@echo "make iso              -- update installer repos, make iso"
	@echo "make check            -- check for any uncommited changes and unsigned tags"
	@echo "make check-depend     -- check for build dependencies ($(DEPENDENCIES))"
	@echo "make diff             -- show diffs for any uncommitted changes"
	@echo "make grep RE=regexp   -- grep for regexp in all components"
	@echo "make push             -- do git push for all repos, including tags"
	@echo "make show-vtags       -- list components version tags (only when HEAD have such) and branches"
	@echo "make show-authors     -- list authors of Qubes code based on commit log of each component"
	@echo "make prepare-merge    -- fetch the sources from git, but only show new commits instead of merging"
	@echo "make show-unmerged    -- list fetched but unmerged commits (see make prepare-merge)"
	@echo "make do-merge         -- merge fetched commits"
	@echo "make COMPONENT        -- build both dom0 and VM part of COMPONENT"
	@echo "make COMPONENT-dom0   -- build only dom0 part of COMPONENT"
	@echo "make COMPONENT-vm     -- build only VM part of COMPONENT"
	@echo "COMPONENT can be one of:"
	@echo "  $(COMPONENTS)"
	@echo ""
	@echo "You can also specify COMPONENTS=\"c1 c2 c3 ...\" on command line"
	@echo "to operate on subset of components. Example: make COMPONENTS=\"gui\" get-sources"

get-sources::
	@set -a; \
	SCRIPT_DIR=$(CURDIR)/scripts; \
	SRC_ROOT=$(CURDIR)/$(SRC_DIR); \
	for REPO in $(GIT_REPOS); do \
		$$SCRIPT_DIR/get-sources || exit 1; \
	done

.PHONY: check-depend
check-depend:
	@if ! which rpm >/dev/null 2>&1; then
		echo "WARNING: rpm executable not found (are you on cygwin?)"; \
	elif [ $(VERBOSE) -gt 0 ]; then \
		echo "currently installed dependencies:"; \
		rpm -q $(DEPENDENCIES) || exit 1; \
	else \
		rpm -q $(DEPENDENCIES) >/dev/null 2>&1 || exit 1; \
	fi

$(filter-out template linux-template-builder kde-dom0 dom0-updates builder, $(COMPONENTS)): % : %-dom0 %-vm

$(filter-out qubes-vm, $(addsuffix -vm,$(COMPONENTS))) : %-vm : check-depend
	@$(call check_branch,$*)
	@if [ -r $(SRC_DIR)/$*/Makefile.builder ]; then \
		for DIST in $(DISTS_VM); do \
			DIST=$${DIST%%+*}; \
			make --no-print-directory DIST=$$DIST PACKAGE_SET=vm COMPONENT=$* -f Makefile.generic all || exit 1; \
		done; \
	elif [ -n "`make -n -s -C $(SRC_DIR)/$* rpms-vm 2> /dev/null`" ]; then \
	    for DIST in $(DISTS_VM); do \
		DIST=$${DIST%%+*}; \
	        MAKE_TARGET="rpms-vm" ./scripts/build $$DIST $* || exit 1; \
	    done; \
	fi

$(filter-out qubes-dom0, $(addsuffix -dom0,$(COMPONENTS))) : %-dom0 : check-depend
	@$(call check_branch,$*)
	@if [ -r $(SRC_DIR)/$*/Makefile.builder ]; then \
		make -f Makefile.generic DIST=$(DIST_DOM0) PACKAGE_SET=dom0 COMPONENT=$* all || exit 1; \
	elif [ -n "`make -n -s -C $(SRC_DIR)/$* rpms-dom0 2> /dev/null`" ]; then \
	    MAKE_TARGET="rpms-dom0" ./scripts/build $(DIST_DOM0) $* || exit 1; \
	fi

# With generic rule it isn't handled correctly (xfce4-dom0 target isn't built
# from xfce4 repo...). "Empty" rule because real package are built by above
# generic rule as xfce4-dom0-dom0
xfce4-dom0:
	@true

# Nothing to be done there
yum-dom0 yum-vm:
	@true

# Some components requires custom rules
template linux-template-builder::
	@for DIST in $(DISTS_VM); do
	    # Allow template flavors to be declared within the DISTS_VM declaration
	    # <distro>+<template flavor>+<template options>+<template options>...
	    dist_array=($${DIST//+/ })
	    DIST=$${dist_array[0]}
	    TEMPLATE_FLAVOR=$${dist_array[1]}
	    TEMPLATE_OPTIONS="$${dist_array[@]:2}"
	    plugins_var="BUILDER_PLUGINS_$$DIST"
	    BUILDER_PLUGINS_COMBINED="$(BUILDER_PLUGINS) $${!plugins_var}"
	    BUILDER_PLUGINS_DIRS=`for d in $$BUILDER_PLUGINS_COMBINED; do echo -n " $(CURDIR)/$(SRC_DIR)/$$d"; done`
	    export BUILDER_PLUGINS_DIRS
	    CACHEDIR=$(CURDIR)/cache/$$DIST
	    export CACHEDIR
	    MAKE_TARGET=rpms
	    if [ "0$(TEMPLATE_ROOT_IMG_ONLY)" -eq "1" ]; then
	        MAKE_TARGET=rootimg-build
	    fi

	    # some sources can be downloaded and verified during template building
	    # process - e.g. archlinux template
	    export GNUPGHOME="$(CURDIR)/keyrings/template-$$DIST"
	    mkdir -p "$$GNUPGHOME"
	    chmod 700 "$$GNUPGHOME"
	    export DIST NO_SIGN TEMPLATE_FLAVOR TEMPLATE_OPTIONS
	    make -s -C $(SRC_DIR)/linux-template-builder prepare-repo-template || exit 1
	    for repo in $(GIT_REPOS); do \
	        if [ -r $$repo/Makefile.builder ]; then
				make --no-print-directory -f Makefile.generic \
					PACKAGE_SET=vm \
					COMPONENT=`basename $$repo` \
					UPDATE_REPO=$(CURDIR)/$(SRC_DIR)/linux-template-builder/pkgs-for-template/$$DIST \
					update-repo || exit 1
	        elif make -C $$repo -n update-repo-template > /dev/null 2> /dev/null; then
	            make -s -C $$repo update-repo-template || exit 1
	        fi
	    done
	    if [ "$(VERBOSE)" -eq 0 ]; then
	        echo "-> Building template $$DIST (logfile: build-logs/template-$$DIST.log)..."
	        make -s -C $(SRC_DIR)/linux-template-builder $$MAKE_TARGET > build-logs/template-$$DIST.log 2>&1 || exit 1
			echo "--> Done."
	    else
	        make -s -C $(SRC_DIR)/linux-template-builder $$MAKE_TARGET || exit 1
	    fi
	done

template-in-dispvm: $(addprefix template-in-dispvm-,$(DISTS_VM))

template-in-dispvm-%: DIST=$*
template-in-dispvm-%:
	BUILDER_TEMPLATE_CONF=$(lastword $(filter $(DIST):%,$(BUILDER_TEMPLATE_CONF)))
	echo "-> Building template $(DIST) (logfile: build-logs/template-$(DIST).log)..."
	./scripts/build_full_template_in_dispvm $(DIST) "$${BUILDER_TEMPLATE_CONF#*:}" > build-logs/template-$(DIST).log 2>&1 || exit 1

# Sign only unsigend files (naturally we don't expext files with WRONG sigs to be here)
sign-all:
	@echo "-> Signing packages..."
	@if ! [ $(NO_SIGN) ] ; then \
		sudo rpm --import qubes-release-*-signing-key.asc ; \
		echo "--> Checking which packages need to be signed (to avoid double signatures)..." ; \
		FILE_LIST=""; for RPM in $(shell ls $(SRC_DIR)/*/rpm/*/*.rpm) windows-tools/rpm/noarch/*.rpm; do \
			if ! $(SRC_DIR)/$(INSTALLER_COMPONENT)/rpm_verify $$RPM > /dev/null; then \
				FILE_LIST="$$FILE_LIST $$RPM" ;\
			fi ;\
		done ; \
		echo "--> Singing..."; \
		RPMSIGN_OPTS=; \
		if [ -n "$$SIGN_KEY" ]; then \
			RPMSIGN_OPTS="--define=%_gpg_name $$SIGN_KEY"; \
			echo "RPMSIGN_OPTS = $$RPMSIGN_OPTS"; \
		fi; \
		sudo chmod go-rw /dev/tty ;\
		echo | rpmsign "$$RPMSIGN_OPTS" --addsign $$FILE_LIST ;\
		sudo chmod go+rw /dev/tty ;\
	else \
		echo  "--> NO_SIGN given, skipping package signing!" ;\
	fi; \
	for dist in $(shell ls qubes-packages-mirror-repo/); do \
		if [ -d qubes-packages-mirror-repo/$$dist/rpm ]; then \
			sudo ./update-local-repo.sh $$dist; \
		fi \
	done

qubes: $(filter-out builder,$(COMPONENTS))

qubes-dom0: $(addsuffix -dom0,$(filter-out builder linux-template-builder,$(COMPONENTS)))

qubes-vm:: $(addsuffix -vm,$(filter-out builder linux-template-builder,$(COMPONENTS)))

qubes-os-iso: get-sources qubes sign-all iso

clean-installer-rpms:
	(cd $(SRC_DIR)/$(INSTALLER_COMPONENT)/yum || cd $(SRC_DIR)/$(INSTALLER_COMPONENT)/yum && ./clean_repos.sh) || true

clean-rpms:: clean-installer-rpms
	@for dist in $(shell ls qubes-packages-mirror-repo/); do \
		echo "Cleaning up rpms in qubes-packages-mirror-repo/$$dist/rpm/..."; \
		sudo rm -rf qubes-packages-mirror-repo/$$dist/rpm/*.rpm || true ;\
		createrepo -q --update qubes-packages-mirror-repo || true; \
	done
	@echo 'Cleaning up rpms in $(SRC_DIR)/*/rpm/*/*...'; \
	sudo rm -fr $(SRC_DIR)/*/rpm/*/*.rpm || true; \


clean:
	@for REPO in $(GIT_REPOS); do \
		echo "$$REPO" ;\
		if ! [ -d $$REPO ]; then \
			continue; \
		elif [ $$REPO == "$(SRC_DIR)/linux-template-builder" ]; then \
			for DIST in $(DISTS_VM); do \
				DIST=$${DIST%%+*} make -s -C $$REPO clean || exit 1; \
			done ;\
		elif [ $$REPO == "$(SRC_DIR)/yum" ]; then \
			echo ;\
		elif [ $$REPO == "." ]; then \
			echo ;\
		else \
			make -s -C $$REPO clean; \
		fi ;\
	done;

clean-all:: clean-rpms clean
	for dir in $${DISTS_ALL[@]%%+*}; do \
		if ! [ -d chroot-$$dir ]; then continue; fi; \
		sudo umount chroot-$$dir/proc; \
		sudo umount chroot-$$dir/tmp/qubes-packages-mirror-repo; \
		sudo rm -rf chroot-$$dir || true; \
	done || true
	sudo rm -rf $(SRC_DIR) || true

.PHONY: iso
iso:
	@echo "-> Preparing for ISO build..."
	@make -s -C $(SRC_DIR)/$(INSTALLER_COMPONENT) clean-repos || exit 1
	@echo "--> Copying RPMs from individual repos..."
	@for repo in $(filter-out linux-template-builder,$(GIT_REPOS)); do \
	    if [ -r $$repo/Makefile.builder ]; then
			make --no-print-directory -f Makefile.generic \
				PACKAGE_SET=dom0 \
				DIST=$(DIST_DOM0) \
				COMPONENT=`basename $$repo` \
				UPDATE_REPO=$(CURDIR)/$(SRC_DIR)/$(INSTALLER_COMPONENT)/yum/qubes-dom0 \
				update-repo || exit 1
	    elif make -s -C $$repo -n update-repo-installer > /dev/null 2> /dev/null; then \
	        if ! make -s -C $$repo update-repo-installer ; then \
				echo "make update-repo-installer failed for repo $$repo"; \
				exit 1; \
			fi \
	    fi; \
	done
	@for DIST in $(DISTS_VM); do \
		DIST=$${DIST%%+*}; \
		if ! DIST=$$DIST UPDATE_REPO=$(CURDIR)/$(SRC_DIR)/$(INSTALLER_COMPONENT)/yum/qubes-dom0 \
			make -s -C $(SRC_DIR)/linux-template-builder update-repo-installer ; then \
				echo "make update-repo-installer failed for template dist=$$DIST"; \
				exit 1; \
		fi \
	done
	if [ "$(LINUX_INSTALLER_MULTIPLE_KERNELS)" == "yes" ]; then \
		ln -f $(SRC_DIR)/linux-kernel*/rpm/x86_64/*.rpm $(SRC_DIR)/$(INSTALLER_COMPONENT)/yum/qubes-dom0/rpm/; \
	fi
	@make -s -C $(SRC_DIR)/$(INSTALLER_COMPONENT) update-repo || exit 1
	@MAKE_TARGET="iso QUBES_RELEASE=$(QUBES_RELEASE)" ./scripts/build $(DIST_DOM0) $(INSTALLER_COMPONENT) root || exit 1
	@ln -f $(SRC_DIR)/$(INSTALLER_COMPONENT)/build/ISO/qubes-x86_64/iso/*.iso iso/ || exit 1
	@echo "The ISO can be found in iso/ subdirectory."
	@echo "Thank you for building Qubes. Have a nice day!"


check:
	@HEADER_PRINTED="" ; for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		git status | grep "^nothing to commit" > /dev/null; \
		if [ $$? -ne 0 ]; then \
			if [ X$$HEADER_PRINTED == X ]; then HEADER_PRINTED="1"; echo "Uncommited changes in:"; fi; \
			echo "> $$REPO"; fi; \
	    popd > /dev/null; \
	done; \
	HEADER_PRINTED="" ; for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		git tag --points-at HEAD | grep ^. > /dev/null; \
		if [ $$? -ne 0 ]; then \
			if [ X$$HEADER_PRINTED == X ]; then HEADER_PRINTED="1"; echo "Unsigned HEADs in:"; fi; \
			echo "> $$REPO"; fi; \
	    popd > /dev/null; \
	done

diff:
	@for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		git status | grep "^nothing to commit" > /dev/null; \
		if [ $$? -ne 0 ]; then \
			(echo -e "Uncommited changes in $$REPO:\n\n"; git diff) | less; \
		fi; \
	    popd > /dev/null; \
	done

grep:
	@for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		git grep "$$RE" | sed -e "s,^,$$REPO/,"; \
	    popd > /dev/null; \
	done

switch-branch:
	@for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		echo -n "$$REPO: "; \
		BRANCH=$(BRANCH); \
		if [ "$$REPO" == "." ]; then
			branch_var="BRANCH_builder"; \
		else \
			branch_var="BRANCH_`basename $${REPO//-/_}`"; \
		fi; \
		[ -n "$${!branch_var}" ] && BRANCH="$${!branch_var}"; \
		CURRENT_BRANCH=`git branch | sed -n -e 's/^\* \(.*\)/\1/p' | tr -d '\n'`; \
		if [ "$$BRANCH" != "$$CURRENT_BRANCH" ]; then \
			git config --get-color color.decorate.tag "red bold"; \
			echo -n "$$CURRENT_BRANCH -> "; \
			git config --get-color "" "reset"; \
			git checkout "$$BRANCH"; \
		else \
			git config --get-color color.decorate.branch "green bold"; \
			echo "$$CURRENT_BRANCH"; \
		fi; \
		git config --get-color "" "reset"; \
	    popd > /dev/null; \
	done

show-vtags:
	@for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		echo -n "$$REPO: "; \
		git config --get-color color.decorate.tag "red bold"; \
		git tag --contains HEAD | grep "^[Rv]" | tr '\n' ' '; \
		git config --get-color "" "reset"; \
		echo -n '('; \
		BRANCH=$(BRANCH); \
		if [ "$$REPO" == "." ]; then
			branch_var="BRANCH_builder"; \
		else \
			branch_var="BRANCH_`basename $${REPO//-/_}`"; \
		fi; \
		[ -n "$${!branch_var}" ] && BRANCH="$${!branch_var}"; \
		CURRENT_BRANCH=`git branch | sed -n -e 's/^\* \(.*\)/\1/p' | tr -d '\n'`; \
		if [ "$$BRANCH" != "$$CURRENT_BRANCH" ]; then \
			git config --get-color color.decorate.tag "yellow bold"; \
		else \
			git config --get-color color.decorate.branch "green bold"; \
		fi; \
		echo -n $$CURRENT_BRANCH; \
		git config --get-color "" "reset"; \
		echo ')'; \
	    popd > /dev/null; \
	done

show-authors:
	@for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		COMPONENT=`basename $$REPO`; \
		[ "$$COMPONENT" == "." ] && COMPONENT=builder; \
		git shortlog -sn | tr -s "\t" ":" | sed "s/^ */$$COMPONENT:/"; \
	    popd > /dev/null; \
	done | awk -F: '{ comps[$$3]=comps[$$3] "\n  " $$1 " (" $$2 ")" } END { for (a in comps) { system("tput bold"); printf a ":"; system("tput sgr0"); print comps[a]; } }'

push:
	@HEADER_PRINTED="" ; for REPO in $(GIT_REPOS); do \
		pushd $$REPO > /dev/null; \
		BRANCH=$(BRANCH); \
		if [ "$$REPO" == "." ]; then
			branch_var="BRANCH_builder"; \
		else \
			branch_var="BRANCH_`basename $${REPO//-/_}`"; \
		fi; \
		[ -n "$${!branch_var}" ] && BRANCH="$${!branch_var}"; \
		PUSH_REMOTE=`git config branch.$$BRANCH.remote`; \
		[ -n "$(GIT_REMOTE)" ] && PUSH_REMOTE="$(GIT_REMOTE)"; \
		if [ -z "$$PUSH_REMOTE" ]; then \
			echo "No remote repository set for $$REPO, branch $$BRANCH,"; \
			echo "set it with 'git config branch.$$BRANCH.remote <remote-name>'"; \
			echo "Not pushing anything!"; \
		else \
			echo "Pushing changes from $$REPO to remote repo $$PUSH_REMOTE $$BRANCH..."; \
			TAGS_FROM_BRANCH=`git log --oneline --decorate $$BRANCH| grep '^.\{7\} (\(HEAD, \)\?tag: '| sed 's/^.\{7\} (\(HEAD, \)\?\(\(tag: [^, )]*\(, \)\?\)*\).*/\2/;s/tag: //g;s/, / /g'`; \
			[ "$(VERBOSE)" == "0" ] && GIT_OPTS=-q; \
			git push $$GIT_OPTS $$PUSH_REMOTE $$BRANCH $$TAGS_FROM_BRANCH; \
			if [ $$? -ne 0 ]; then exit 1; fi; \
		fi; \
		popd > /dev/null; \
	done; \
	echo "All stuff pushed succesfully."
	
# Force bash for some advanced substitution (eg ${!...})
SHELL = /bin/bash
-prepare-merge:
	@set -a; \
	SCRIPT_DIR=$(CURDIR)/scripts; \
	SRC_ROOT=$(CURDIR)/$(SRC_DIR); \
	FETCH_ONLY=1; \
	REPOS="$(GIT_REPOS)"; \
	components_var="REMOTE_COMPONENTS_$${GIT_REMOTE//-/_}"; \
	[ -n "$${!components_var}" ] && REPOS="`echo $${!components_var} | sed 's@^\| @ $(SRC_DIR)/@g'`"; \
	for REPO in $$REPOS; do \
		$$SCRIPT_DIR/get-sources || exit 1; \
	done;

prepare-merge: -prepare-merge show-unmerged

show-unmerged:
	@set -a; \
	REPOS="$(GIT_REPOS)"; \
	echo "Changes to be merged:"; \
	for REPO in $$REPOS; do \
		pushd $$REPO > /dev/null; \
		if [ -n "`git log ..FETCH_HEAD 2>/dev/null`" ]; then \
			if [ -n "`git rev-list FETCH_HEAD..HEAD`" ]; then \
				MERGE_TYPE="`git config --get-color color.decorate.tag 'red bold'`"; \
				MERGE_TYPE="$${MERGE_TYPE}merge"; \
			else \
				MERGE_TYPE="`git config --get-color color.decorate.tag 'green bold'`"; \
				MERGE_TYPE="$${MERGE_TYPE}fast-forward"; \
			fi; \
			MERGE_TYPE="$${MERGE_TYPE}`git config --get-color '' 'reset'`"; \
			echo "> $$REPO $$MERGE_TYPE: git merge FETCH_HEAD"; \
			git log --pretty=oneline --abbrev-commit ..FETCH_HEAD; \
		fi; \
		popd > /dev/null; \
	done

do-merge:
	@set -a; \
	REPOS="$(GIT_REPOS)"; \
	for REPO in $$REPOS; do \
		pushd $$REPO > /dev/null; \
		echo "Merging FETCH_HEAD into $$REPO"; \
		git merge --no-edit FETCH_HEAD || exit 1; \
		popd > /dev/null; \
	done

update-repo-current-testing update-repo-security-testing update-repo-unstable: update-repo-%:
	@dom0_var="LINUX_REPO_$(DIST_DOM0)_BASEDIR"; \
	[ -n "$${!dom0_var}" ] && repo_dom0_basedir="`echo $${!dom0_var}`" || repo_dom0_basedir="$(LINUX_REPO_BASEDIR)"; \
	repos_to_update="$$repo_dom0_basedir"; \
	for REPO in $(GIT_REPOS); do \
		[ $$REPO == '.' ] && break; \
		if [ -r $$REPO/Makefile.builder ]; then \
			echo "Updating $$REPO..."; \
			make -s -f Makefile.generic DIST=$(DIST_DOM0) PACKAGE_SET=dom0 \
				UPDATE_REPO=$(CURDIR)/$$repo_dom0_basedir/$*/dom0/$(DIST_DOM0) \
				COMPONENT=`basename $$REPO` \
				SNAPSHOT_FILE=$(CURDIR)/repo-latest-snapshot/$*-dom0-$(DIST_DOM0)-`basename $$REPO` \
				update-repo; \
			for DIST in $(DISTS_VM); do \
				DIST=$${DIST%%+*}; \
				vm_var="LINUX_REPO_$${DIST}_BASEDIR"; \
				[ -n "$${!vm_var}" ] && repo_vm_basedir="`echo $${!vm_var}`" || repo_vm_basedir="$(LINUX_REPO_BASEDIR)"; \
				repos_to_update+=" $$repo_vm_basedir"; \
				make -s -f Makefile.generic DIST=$$DIST PACKAGE_SET=vm \
					UPDATE_REPO=$(CURDIR)/$$repo_vm_basedir/$*/vm/$$DIST \
					COMPONENT=`basename $$REPO` \
					SNAPSHOT_FILE=$(CURDIR)/repo-latest-snapshot/$*-vm-$$DIST-`basename $$REPO` \
					update-repo; \
			done; \
		elif make -C $$REPO -n update-repo-$* >/dev/null 2>/dev/null; then \
			echo "Updating $$REPO... "; \
			make -s -C $$REPO update-repo-$* || echo; \
		else \
			echo "Updating $$REPO... skipping."; \
		fi; \
	done; \
	for repo in `echo $$repos_to_update|tr ' ' '\n'|sort|uniq`; do \
		[ -z "$$repo" ] && continue; \
		(cd $$repo/.. && ./update_repo-$*.sh); \
	done

update-repo-current:
	dom0_var="LINUX_REPO_$(DIST_DOM0)_BASEDIR"; \
	[ -n "$${!dom0_var}" ] && repo_dom0_basedir="`echo $${!dom0_var}`" || repo_dom0_basedir="$(LINUX_REPO_BASEDIR)"; \
	repos_to_update="$$repo_dom0_basedir"; \
	for DIST in $(DISTS_VM); do \
		DIST=$${DIST%%+*}; \
		vm_var="LINUX_REPO_$${DIST}_BASEDIR"; \
		[ -n "$${!vm_var}" ] && repo_vm_basedir="`echo $${!vm_var}`" || repo_vm_basedir="$(LINUX_REPO_BASEDIR)"; \
		repos_to_update+=" $$repo_vm_basedir"; \
	done; \
	for repo in `echo $$repos_to_update|tr ' ' '\n'|sort|uniq`; do \
		[ -z "$$repo" ] && continue; \
		(cd $$repo/.. && ./commit-testing-to-current.sh "$(CURDIR)/repo-latest-snapshot" "$(COMPONENTS)"); \
	done

windows-image:
	./win-mksrcimg.sh

windows-image-extract:
	./win-mountsrc.sh mount || exit 1
	( shopt -s nullglob; cd mnt; cp --parents -rft .. qubes-src/*/*.{msi,exe} )
	for REPO in $(GIT_REPOS); do \
		[ $$REPO == '.' ] && break; \
		if [ -r $$REPO/Makefile.builder ]; then \
			make -s -f Makefile.generic DIST=$(DIST_DOM0) PACKAGE_SET=dom0 \
				WINDOWS_IMAGE_DIR=$(CURDIR)/mnt \
				COMPONENT=`basename $$REPO` \
				DIST=dummy \
				windows-image-extract; \
		fi; \
	done; \
	./win-mountsrc.sh umount

# Returns variable value
# Example usage: GET_VAR=DISTS_VM make get-var
.PHONY: get-var
get-var::
	@GET_VAR=$${!GET_VAR}; \
	echo "$${GET_VAR}"

.PHONY: install-deps
install-deps::
	@sudo yum install -y $(DEPENDENCIES)
