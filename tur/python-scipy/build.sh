TERMUX_PKG_HOMEPAGE=https://scipy.org/
TERMUX_PKG_DESCRIPTION="Fundamental algorithms for scientific computing in Python"
TERMUX_PKG_LICENSE="BSD 3-Clause"
TERMUX_PKG_MAINTAINER="@termux-user-repository"
TERMUX_PKG_VERSION=1.8.0
TERMUX_PKG_SRCURL=https://github.com/scipy/scipy.git
TERMUX_PKG_DEPENDS="libc++, openblas, python, python-numpy"
TERMUX_PKG_BUILD_DEPENDS="python-numpy-static"
TERMUX_PKG_BUILD_IN_SRC=true

# Tests will hang on arm and will failed with `Segmentation fault` on i686.
# See https://github.com/termux-user-repository/tur/pull/21#issue-1295483266.
# 
# The logs of this crash on i686 are as following. 
# linalg/tests/test_basic.py: Fatal Python error: Segmentation fault
# 
# Current thread 0xf7f4b580 (most recent call first):
#   File "/data/data/com.termux/files/usr/lib/python3.10/site-packages/scipy-1.8.0-py3.10-linux-i686.egg/scipy/linalg/_basic.py", line 1227 in lstsq
#   File "/data/data/com.termux/files/usr/lib/python3.10/site-packages/scipy-1.8.0-py3.10-linux-i686.egg/scipy/linalg/tests/test_basic.py", line 1047 in test_simple_overdet_complex
TERMUX_PKG_BLACKLISTED_ARCHES="arm, i686"

TERMUX_PKG_RM_AFTER_INSTALL="
bin/
"

source $TERMUX_SCRIPTDIR/common-files/setup_toolchain_ndk_r17c.sh
source $TERMUX_SCRIPTDIR/common-files/setup_cmake_with_gcc.sh

termux_step_configure() {
	if $TERMUX_ON_DEVICE_BUILD; then
		termux_error_exit "Package '$TERMUX_PKG_NAME' is not available for on-device builds."
	fi

	_PYTHON_VERSION=$(. $TERMUX_SCRIPTDIR/packages/python/build.sh; echo $_MAJOR_VERSION)
	_NUMPY_VERSION=$(. $TERMUX_SCRIPTDIR/packages/python-numpy/build.sh; echo $TERMUX_PKG_VERSION)
	_PKG_PYTHON_DEPENDS="numpy==$_NUMPY_VERSION"

	_setup_toolchain_ndk_with_gfortran_11

	LDFLAGS="${LDFLAGS/-static-openmp/}"

	# XXX: `python` from main repo is built by TERMUX_STANDALONE_TOOLCHAIN and its _sysconfigdata.py
	# XXX: contains some FLAGS which is not supported by GNU Compiler Collections, such as 
	# XXX: `-static-openmp`. So use a wrapper of $PLATFORM-gfortran to ignore these options.
	mkdir -p $TERMUX_PKG_TMPDIR/fake-bin
	cat $TERMUX_PKG_BUILDER_DIR/fake-gfortran > $TERMUX_PKG_TMPDIR/fake-bin/$TERMUX_HOST_PLATFORM-gfortran
	chmod +x $TERMUX_PKG_TMPDIR/fake-bin/$TERMUX_HOST_PLATFORM-gfortran
	export PATH="$TERMUX_PKG_TMPDIR/fake-bin:$PATH"

	# We set `python-scipy` as dependencies, but python-crossenv prefer to use a fake one.
	DEVICE_STIE=$TERMUX_PREFIX/lib/python${_PYTHON_VERSION}/site-packages
	pushd $DEVICE_STIE
	_NUMPY_EGGDIR=
	for f in numpy-${_NUMPY_VERSION}-py${_PYTHON_VERSION}-linux-*.egg; do
		if [ -d "$f" ]; then
			_NUMPY_EGGDIR="$f"
			break
		fi
	done
	test -n "${_NUMPY_EGGDIR}"
	popd
	mv $DEVICE_STIE/$_NUMPY_EGGDIR $TERMUX_PREFIX/tmp/$_NUMPY_EGGDIR

	termux_setup_python_crossenv
	pushd $TERMUX_PYTHON_CROSSENV_SRCDIR
	_CROSSENV_PREFIX=$TERMUX_PKG_BUILDDIR/python-crossenv-prefix
	python${_PYTHON_VERSION} -m crossenv \
		$TERMUX_PREFIX/bin/python${_PYTHON_VERSION} \
		${_CROSSENV_PREFIX}
	popd
	. ${_CROSSENV_PREFIX}/bin/activate

	LDFLAGS+=" -Wl,--no-as-needed,-lpython${_PYTHON_VERSION}"
}

termux_step_make() {
	MATHLIB="m" pip --no-cache-dir install $_PKG_PYTHON_DEPENDS wheel
	build-pip install $_PKG_PYTHON_DEPENDS pybind11 Cython pythran wheel

	# From https://gist.github.com/benfogle/85e9d35e507a8b2d8d9dc2175a703c22
	BUILD_SITE=${_CROSSENV_PREFIX}/build/lib/python${_PYTHON_VERSION}/site-packages
	CROSS_SITE=${_CROSSENV_PREFIX}/cross/lib/python${_PYTHON_VERSION}/site-packages
	INI=$(find $BUILD_SITE -name 'npymath.ini')
	LIBDIR=$(find $CROSS_SITE -path '*/numpy/core/lib')
	INCDIR=$(find $CROSS_SITE -path '*/numpy/core/include')
	cat <<-EOF > $INI 
	[meta]
	Name=npymath
	Description=Portable, core math library implementing C99 standard
	Version=0.1
	[variables]
	# Force it to find cross-build libs when we build scipy
	libdir=$LIBDIR
	includedir=$INCDIR
	[default]
	Libs=-L\${libdir} -lnpymath
	Cflags=-I\${includedir}
	Requires=mlib
	EOF
	_ADDTIONAL_FILES=()
	cp $CROSS_SITE/numpy/core/lib/libnpymath.a $TERMUX_PREFIX/lib
	cp $CROSS_SITE/numpy/random/lib/libnpyrandom.a $TERMUX_PREFIX/lib
	_ADDTIONAL_FILES+=("$TERMUX_PREFIX/lib/libnpymath.a")
	_ADDTIONAL_FILES+=("$TERMUX_PREFIX/lib/libnpyrandom.a")
	cat <<- EOF > site.cfg
	[openblas]
	libraries = openblas
	library_dirs = $TERMUX_PREFIX/lib
	include_dirs = $TERMUX_PREFIX/include
	EOF

	F90=$FC F77=$FC python setup.py install --force
}

termux_step_make_install() {
	export PYTHONPATH="$DEVICE_STIE"
	F90=$FC F77=$FC python setup.py install --force --prefix $TERMUX_PREFIX

	pushd $DEVICE_STIE
	_SCIPY_EGGDIR=
	for f in scipy-${TERMUX_PKG_VERSION}-py${_PYTHON_VERSION}-linux-*.egg; do
		if [ -d "$f" ]; then
			_SCIPY_EGGDIR="$f"
			break
		fi
	done
	test -n "${_SCIPY_EGGDIR}"
	popd
}

termux_step_post_make_install() {
	# Remove these dummy files.
	rm "${_ADDTIONAL_FILES[@]}"
	# Recovery numpy
	mv $TERMUX_PREFIX/tmp/$_NUMPY_EGGDIR $DEVICE_STIE/$_NUMPY_EGGDIR
	# Delete the easy-install related files, since we use postinst/prerm to handle it.
	pushd $TERMUX_PREFIX
	rm -rf lib/python${_PYTHON_VERSION}/site-packages/__pycache__
	rm -rf lib/python${_PYTHON_VERSION}/site-packages/easy-install.pth
	rm -rf lib/python${_PYTHON_VERSION}/site-packages/site.py
	popd
}

termux_step_create_debscripts() {
	cat <<- EOF > ./postinst
	#!$TERMUX_PREFIX/bin/sh
	echo "Installing dependencies through pip. This may take a while..."
	pip3 install ${_PKG_PYTHON_DEPENDS}
	echo "./${_SCIPY_EGGDIR}" >> $TERMUX_PREFIX/lib/python${_PYTHON_VERSION}/site-packages/easy-install.pth
	EOF

	cat <<- EOF > ./prerm
	#!$TERMUX_PREFIX/bin/sh
	sed -i "/\.\/${_SCIPY_EGGDIR//./\\.}/d" $TERMUX_PREFIX/lib/python${_PYTHON_VERSION}/site-packages/easy-install.pth
	EOF
}
