# This script is used to initialize a number of env variables and setup the
# runtime environment of logstash. It sets to following env variables:
#   LOGSTASH_HOME & LS_HOME
#   SINCEDB_DIR
#   JAVACMD
#   JAVA_OPTS
#   GEM_HOME & GEM_PATH
#   DEBUG
#
# These functions are provided for the calling script:
#   setup() to setup the environment
#   ruby_exec() to execute a ruby script with using the setup runtime environment
#
# The following env var will be used by this script if set:
#   LS_GEM_HOME and LS_GEM_PATH to overwrite the path assigned to GEM_HOME and GEM_PATH
#   LS_JAVA_OPTS to append extra options to the JVM options provided by logstash
#   LS_JAVA_HOME to point to the java home

unset CDPATH
# This unwieldy bit of scripting is to try to catch instances where Logstash
# was launched from a symlink, rather than a full path to the Logstash binary
if [ -L "$0" ]; then
  # Launched from a symlink
  # --Test for the readlink binary
  RL="$(command -v readlink)"
  if [ $? -eq 0 ]; then
    # readlink exists
    SOURCEPATH="$($RL $0)"
  else
    # readlink not found, attempt to parse the output of stat
    SOURCEPATH="$(stat -c %N $0 | awk '{print $3}' | sed -e 's/\‘//' -e 's/\’//')"
    if [ $? -ne 0 ]; then
      # Failed to execute or parse stat
      echo "Failed to set LOGSTASH_HOME from $(cd `dirname $0`/..; pwd)/bin/logstash.lib.sh"
      echo "You may need to launch Logstash with a full path instead of a symlink."
      exit 1
    fi
  fi
else
  # Not a symlink
  SOURCEPATH="$0"
fi

LOGSTASH_HOME="$(cd `dirname $SOURCEPATH`/..; pwd)"
export LOGSTASH_HOME
export LS_HOME="${LOGSTASH_HOME}"
SINCEDB_DIR="${LOGSTASH_HOME}"
export SINCEDB_DIR
LOGSTASH_JARS=${LOGSTASH_HOME}/logstash-core/lib/jars

# iterate over the command line args and look for the argument
# after --path.settings to see if the jvm.options file is in
# that path and set LS_JVM_OPTS accordingly
# This fix is for #6379
unset LS_JVM_OPTS
found=0
for i in "$@"; do
 if [ $found -eq 1 ]; then
   if [ -r "${i}/jvm.options" ]; then
     export LS_JVM_OPTS="${i}/jvm.options"
     break
   fi
 fi
 if [ "$i" = "--path.settings" ]; then
   found=1
 fi
done

setup_bundled_jdk_part() {
  OS_NAME="$(uname -s)"
  if [ $OS_NAME = "Darwin" ]; then
    BUNDLED_JDK_PART="jdk.app/Contents/Home"
  else
    BUNDLED_JDK_PART="jdk"
  fi
}

# Accepts 1 parameter which is the path the directory where logstash jar are contained.
setup_classpath() {
  local jar_directory="${1?jar directory required}"
  local classpath
  for J in $(cd "${jar_directory}"; ls *.jar); do
    classpath=${classpath}${classpath:+:}${jar_directory}/${J}
  done
  echo "${classpath}"
}

setup_java() {
  # set the path to java into JAVACMD which will be picked up by JRuby to launch itself
  if [ -z "$JAVACMD" ]; then
    setup_bundled_jdk_part
    JAVACMD_TEST=`command -v java`
    if [ -n "$LS_JAVA_HOME" ]; then
      echo "Using LS_JAVA_HOME defined java: ${LS_JAVA_HOME}."
      if [ -x "$LS_JAVA_HOME/bin/java" ]; then
        JAVACMD="$LS_JAVA_HOME/bin/java"
        if [ -d "${LOGSTASH_HOME}/${BUNDLED_JDK_PART}" -a -x "${LOGSTASH_HOME}/${BUNDLED_JDK_PART}/bin/java" ]; then
          echo "WARNING: Using LS_JAVA_HOME while Logstash distribution comes with a bundled JDK."
        fi
      else
        echo "Invalid LS_JAVA_HOME, doesn't contain bin/java executable."
      fi
    elif [ -d "${LOGSTASH_HOME}/${BUNDLED_JDK_PART}" -a -x "${LOGSTASH_HOME}/${BUNDLED_JDK_PART}/bin/java" ]; then
      echo "Using bundled JDK: ${LOGSTASH_HOME}/${BUNDLED_JDK_PART}"
      JAVACMD="${LOGSTASH_HOME}/${BUNDLED_JDK_PART}/bin/java"
    elif [ -n "$JAVACMD_TEST" ]; then
      set +e
      JAVACMD=`command -v java`
      set -e
      echo "Using system java: $JAVACMD"
    fi
  fi

  if [ ! -x "$JAVACMD" ]; then
    echo "Could not find java; set LS_JAVA_HOME or ensure java is in PATH."
    exit 1
  fi

  # do not let JAVA_TOOL_OPTIONS slip in (as the JVM does by default)
  if [ ! -z "$JAVA_TOOL_OPTIONS" ]; then
    echo "warning: ignoring JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS"
    unset JAVA_TOOL_OPTIONS
  fi

  # JAVA_OPTS is not a built-in JVM mechanism but some people think it is so we
  # warn them that we are not observing the value of $JAVA_OPTS
  if [ ! -z "$JAVA_OPTS" ]; then
    echo -n "warning: ignoring JAVA_OPTS=$JAVA_OPTS; "
    echo "pass JVM parameters via LS_JAVA_OPTS"
  fi

  # Set a default GC log file for use by jvm.options _before_ it's called.
  if [ -z "$LS_GC_LOG_FILE" ] ; then
    LS_GC_LOG_FILE="./logstash-gc.log"
  fi

  # jruby launcher uses JAVACMD as its java executable and JAVA_OPTS as the JVM options
  export JAVACMD

  CLASSPATH="$(setup_classpath $LOGSTASH_JARS)"

  # Verify the version of Java being used, and exit if the wrong version of Java is not available.
  if ! "${JAVACMD}" -cp "${CLASSPATH}" org.logstash.util.JavaVersionChecker ; then
    exit 1
  fi
  JAVA_OPTS=`exec "${JAVACMD}" -cp "${CLASSPATH}" org.logstash.launchers.JvmOptionsParser "$LOGSTASH_HOME" "$LS_JVM_OPTS"`
  unset CLASSPATH
  export JAVA_OPTS
}

setup_vendored_jruby() {
  JRUBY_BIN="${LOGSTASH_HOME}/vendor/jruby/bin/jruby"

  if [ ! -f "${JRUBY_BIN}" ] ; then
    echo "Unable to find JRuby."
    echo "If you are a user, this is a bug."
    echo "If you are a developer, please run 'rake bootstrap'. Running 'rake' requires the 'ruby' program be available."
    exit 1
  fi

  if [ -z "$LS_GEM_HOME" ] ; then
    export GEM_HOME="${LOGSTASH_HOME}/vendor/bundle/jruby/2.5.0"
  else
    export GEM_HOME=${LS_GEM_HOME}
  fi
  if [ "$DEBUG" ] ; then
    echo "Using GEM_HOME=${GEM_HOME}"
  fi

  if [ -z "$LS_GEM_PATH" ] ; then
    export GEM_PATH=${GEM_HOME}
  else
    export GEM_PATH=${LS_GEM_PATH}
  fi
  if [ "$DEBUG" ] ; then
    echo "Using GEM_PATH=${GEM_PATH}"
  fi
}

setup() {
  setup_java
  setup_vendored_jruby
}

ruby_exec() {
  if [ "$DEBUG" ] ; then
    echo "DEBUG: exec ${JRUBY_BIN} $@"
  fi
  exec "${JRUBY_BIN}" "$@"
}
